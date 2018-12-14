/**
*
*   RESITANCE PLASMID IDENTIFICATION PIPELINE
*
*   Nextflow pipeline to analyse assembled bacterial genomes 
*   using long reads to identify circular plasmids with and
*   antibiotical resistance genes
*   Caspar Gross 2018
* 
**/


samples = getFiles(params.input)

// Duplicate channel
samples.into{samples_rgi; samples_gc; samples_split; samples_map; samples_table}

// Split into contigs and filter for length channel
samples_split
    .map{[
        it['id'],
        file(it.get('assembly')),
        it['lr']
        ]}
    .splitFasta(record: [id: true, seqString: true])
    .map{
        def id = it[0]
        def lr = it[2]
        def contigName = it[1]['id']
        def length = it[1]['seqString'].length()
        def sequence = it[1]['seqString']
        [id, lr, contigName, length, sequence]
       }
    .filter{it[3] < params.maxLength}
  //.view()
    .into{contigs; contigs_2}


process pad_plasmids {
// Add prefix and suffix with sequence from oppsig end to each plasmid
    tag{id + ":" + contigName}

    input: 
    set id, lr, contigName, length, sequence from contigs_2

    output: 
    set id, file("${id}_${contigName}_padded.fasta"), lr, contigName into contigs_padded
    
    shell:
    '''
    echo '>!{contigName}' >  !{id}_!{contigName}_padded.fasta

    echo !{sequence} | awk '{print \
        substr($1, length($1)-(!{params.seqPadding} - 1), length($1))\
        $1 \
        substr($1, 1, !{params.seqPadding})\
        }' >> !{id}_!{contigName}_padded.fasta

    '''
}

process combine_padded_contigs {
// Recombines padded contigs into a single fasta
    tag{id + ":" + contigName}

    input:
    set id, assembly, lr, contigName from contigs_padded.groupTuple()

    output:
    set id, file("${id}_padded.fasta"), lr, val("padded") into map_padded

    script:
    """
    cat \$(echo ${assembly} | tr -d '[],') > ${id}_padded.fasta 
    """
}

// Mix channel with padded and normal contigs
samples_map
  //.view()
    .map{[it['id'], 
        it['assembly'], 
        it['lr'], 
        'normal']}
    .mix(map_padded
        .map{[it[0], 
            it[1], 
            it[2][1],
            it[3]]})
  //.view()
    .set{to_mapping}

process map_longreads {
// Use minimap2 to align longreads to padded contigs
    publishDir "${params.outDir}/${id}/alignment/", mode: 'copy'
    tag{id}

    input:
    set id, assembly, lr, type from to_mapping

    output:
    set id, assembly, type, file("${id}_${type}_lr.bam"), file("${id}_${type}_lr.bai") into bam_lr

    script:
    """
    minimap2 -ax map-ont -t ${params.cpu} ${assembly} ${lr} \
    | samtools sort | samtools view -b -F 4 -o  ${id}_${type}_lr.bam 
    samtools index ${id}_${type}_lr.bam ${id}_${type}_lr.bai
    """
}

// Distribute bamfiles for coverage and read overlap identification
bam_cov = Channel.create()
bam_ovlp = Channel.create()
bam_lr.into{bam_cov; bam_ovlp}

process find_ovlp_reads {
// Creates circos file from bam, uses R script to find overlapping reads
    tag{id + ":" + contig_name}

    input:
    set id, lr, contig_name, length, seq, file(assembly), type, bam, bai from contigs.combine(bam_ovlp.filter{it[2] == 'padded'}, by : 0)

    output:
    set id, contig_name, length, file("reads.txt"), file("ovlp.txt"), file("cov_ovlp.txt") into circos_reads 

    script:
    """
    bedtools bamtobed -i ${bam} > reads.bed
    echo -e ${contig_name}'\\t'\$(expr ${params.seqPadding} )'\\t'\$(expr ${params.seqPadding} + 10) > breaks.bed
    echo -e ${contig_name}'\\t'\$(expr ${length} - ${params.seqPadding} - 10)'\\t'\$(expr ${length} - ${params.seqPadding} + 10) >> breaks.bed
    bedtools intersect -wa  -a reads.bed -b breaks.bed > ovlp.bed
    
    awk '{print \$4}' ovlp.bed | uniq -D | uniq > readID.txt
    samtools view -H ${bam} > ovlp.sam 
    samtools view ${bam} | grep -f readID.txt >> ovlp.sam || true
    samtools view -b ovlp.sam > ovlp.bam
    samtools index ovlp.bam
    
    source activate mosdepth
    mosdepth -t ${params.cpu} -n -b ${params.covWindow} ${contig_name} ovlp.bam
    gunzip -c ${contig_name}.regions.bed.gz > cov_ovlp.bed
    
    03_prepare_bed.R ovlp.bed ${params.seqPadding} ovlp.txt  TRUE FALSE ${contig_name} ${length}
    03_prepare_bed.R cov_ovlp.bed 0 cov_ovlp.txt FALSE TRUE
    03_prepare_bed.R reads.bed ${params.seqPadding} reads.txt FALSE FALSE ${contig_name} ${length}
    """
}

process identify_resistance_genes {
// Find antibiotic resistance genes in the CARD database
    publishDir "${params.outDir}/${id}/resistances", mode: 'copy'
    tag{id}

    input:
    set id, assembly, lr from samples_rgi
    
    output:
    set id, file("${id}_rgi.txt") into from_rgi

    script:
    """
    source activate rgi
    rgi main -i ${assembly} -n ${params.cpu} -o ${id}_rgi
    """
}

from_rgi.into{rgi_txt; table_data_rgi}

process format_data_rgi {
// Converts gff file to circos readable format    
    tag{id}

    input:
    set id, rgi from rgi_txt

    output:
    set id, file("rgi.txt"), file("rgi_span.txt") into circos_data_rgi

    script:
    """
    02_create_rgi_circos.R ${rgi}
    """
}

process mos_depth {
// Calculate coverage depth
    publishDir "${params.outDir}/${id}/coverage", mode: 'copy'
    tag{id}

    input:
    set id, assembly, type, aln_lr, aln_lr_idx from bam_cov

    output:
    file("${id}_cov_${type}.bed.gz")
    set id, file("${id}_cov_${type}.bed.gz"), type into cov_bed

    script:
    """
    source activate mosdepth
    mosdepth -t ${params.cpu} -n -b ${params.covWindow} ${id} ${aln_lr} 
    mv ${id}.regions.bed.gz ${id}_cov_${type}.bed.gz
    """
}

process format_data_cov {
// Formats coverage data for use in circos
    tag{id}
    
    input:
    set id, bed, type from cov_bed

    output:
    set id, file("cov.txt"), type into cov_formated

    script:
    if (type == "padded")
        """
        gunzip -c ${bed} > cov.bed
        03_prepare_bed.R cov.bed ${params.seqPadding} cov.txt FALSE TRUE
        """
    else
        """
        gunzip -c ${bed} > cov.bed
        03_prepare_bed.R cov.bed 0 cov.txt FALSE TRUE
        """
}

// Distribute coverage file for circos (padded)  and summary table (normal)
circos_data_cov = Channel.create()
table_data_cov = Channel.create()
cov_formated.choice(circos_data_cov, table_data_cov) { it[2] == 'padded' ? 0 : 1 }

process calcGC {
// Calculate gc conten
    publishDir "${params.outDir}/${id}/gc", mode: 'copy'
    tag{id}

    input:
    set id, assembly, lr from samples_gc
    
    output:
    set id, file('gc1000.txt'), assembly into table_data_gc
    set id, file('gc50.txt'), file('gc1000.txt') into circos_data_gc

    script:
    """
    01_calculate_GC.R ${assembly} 
    """
}

// Combine all finished circos data based on the id
circos_data_gc
   .join(circos_data_cov)
       .join(circos_data_rgi)
       .set{circos_data}

// Combine contig data with sample wide circos data
combined_data = circos_reads.combine(circos_data, by: 0)

// Combine all table data based on id
table_data_gc
    .join(table_data_cov)
        .join(table_data_rgi)
        .set{table_data}

process circos{
// Use the combined data to create circular plots
    publishDir "${params.outDir}/${id}/plots", mode: 'copy'
    tag{id + ":" + contigID}

    input:
    set id, contigID, length, file(reads), file(ovlp), file(cov_ovlp), file(gc50), file(gc1000), file(cov), type, file(rgi), file(rgi_span) from combined_data

    output:
    file("${id}_${contigID}_plasmid.*")

    script:
    """
    echo "chr	-	${contigID}	1	0	${length}	chr1	color=lblue" > contig.txt
    ln -s ${workflow.projectDir}/conf/circos//* .
    circos
    mv circos.png ${id}_${contigID}_plasmid.png
    mv circos.svg ${id}_${contigID}_plasmid.svg
    """
}

process table{
// Create table with contig informations
    publishDir "${params.outDir}/${id}/", mode: 'copy'
    tag{id}

    input:
    set id, gc, assembly, cov, type, rgi from table_data

    output:
    file("${id}_summary.csv")

    script:
    """
    04_summary_table.R ${assembly} ${rgi} ${cov} ${gc}
    mv contig_summary.txt ${id}_summary.csv
    """
}


/*
================================================================================
=                               F U N C T I O N S                              =
================================================================================
*/

def getFiles(tsvFile) {
  // Extracts Read Files from TSV
  log.info "Reading  input file: " + tsvFile
  log.info "------------------------------"
  Channel.fromPath(tsvFile)
      .ifEmpty {exit 1, log.info "Cannot find path file ${tsvFile}"}
      .splitCsv(sep:'\t', skip: 1)
      .map { row ->
            [id:row[0], assembly:returnFile(row[1]), lr:returnFile(row[2])]
            }   
}

def returnFile(it) {
// Return file if it exists
    if (workflow.profile in ['test', 'localtest'] ) {
        inputFile = file("$workflow.projectDir/data/" + it)
    } else {
        inputFile = file(it)
    }
    if (!file(inputFile).exists()) exit 1, "Missing file in TSV file: ${inputFile}, see --help for more information"
    return inputFile
}


def helpMessage() {
  // Display help message
  // this.pipelineMessage()
  log.info "  Usage:"
  log.info "       nextflow run caspargross/hybridAssembly --input <file.csv> --mode <mode1,mode2...> [options] "
  log.info "    --input <file.tsv>"
  log.info "       TSV file containing paths to read files (id | shortread2| shortread2 | longread)"
  log.info "    --mode {${validModes}}"
  log.info "       Default: none, choose one or multiple modes to run the pipeline "
  log.info " "
  log.info "  Parameters: "
  log.info "    --outDir "
  log.info "    Output locattion (Default: current working directory"
  log.info "    --genomeSize <bases> (Default: 5300000)"
  log.info "    Expected genome size in bases."
  log.info "    --targetShortReadCov <coverage> (Default: 60)"
  log.info "    Short reads will be downsampled to a maximum of this coverage"
  log.info "    --targetLongReadCov <coverage> (Default: 60)"
  log.info "    Long reads will be downsampled to a maximum of this coverage"
  log.info "    --cpu <threads>"
  log.info "    set max number of threads per process"
  log.info "    --mem <Gb>"
  log.info "    set max amount of memory per process"
  log.info "    --minContigLength <length>"
  log.info "    filter final contigs for minimum length (Default: 1000)"
  log.info "          "
  log.info "  Options:"
//  log.info "    --shortRead"
//  log.info "      Uses only short reads. Only 'spades_simple', 'spades_plasmid' and 'unicycler' mode."
//  log.info "    --longRead"
//  log.info "      Uses long read only. Only 'unicycler', 'miniasm', 'canu' and 'flye'"
//  log.info "    --fast"
//  log.info "      Skips some steps to run faster. Only one cycle of error correction'" 
  log.info "    --version"
  log.info "      Displays pipeline version"
  log.info "           "
  log.info "  Profiles:"
  log.info "    -profile local "
  log.info "    Pipeline runs with locally installed conda environments (found in env/ folder)"
  log.info "    -profile test "
  log.info "    Runs complete pipeline on small included test dataset"
  log.info "    -profile localtest "
  log.info "    Runs test profile with locally installed conda environments"


}



def grabRevision() {
  // Return the same string executed from github or not
  return workflow.revision ?: workflow.commitId ?: workflow.scriptId.substring(0,10)
}

def minimalInformationMessage() {
  // Minimal information message
  log.info "Command Line  : " + workflow.commandLine
  log.info "Profile       : " + workflow.profile
  log.info "Project Dir   : " + workflow.projectDir
  log.info "Launch Dir    : " + workflow.launchDir
  log.info "Work Dir      : " + workflow.workDir
  log.info "Cont Engine   : " + workflow.containerEngine
  log.info "Out Dir       : " + params.outDir
  log.info "Align. Overlp.: " + params.seqPadding
  log.info "Cov. window   : " + params.covWindow
  log.info "Max Plasm. Len: " + params.maxLength
  log.info "Containers    : " + workflow.container 
}

def pipelineMessage() {
  // Display hybridAssembly info  message
  log.info "PlasmIdent Pipeline ~  version ${workflow.manifest.version} - revision " + this.grabRevision() + (workflow.commitId ? " [${workflow.commitId}]" : "")
}

def startMessage() {
  // Display start message
  // this.asciiArt()
  this.pipelineMessage()
  this.minimalInformationMessage()
}

workflow.onComplete {
  // Display complete message
  log.info "Completed at: " + workflow.complete
  log.info "Duration    : " + workflow.duration
  log.info "Success     : " + workflow.success
  log.info "Exit status : " + workflow.exitStatus
}


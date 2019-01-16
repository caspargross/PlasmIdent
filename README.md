PlasmIdent
==========

[![Build Status](https://travis-ci.org/caspargross/PlasmIdent.svg?branch=master)](https://travis-ci.org/caspargross/PlasmIdent)

This pipeline idenfitifes circular plasmids in in bacterial genome assemblies using long reads.

It includes the following steps
- Gene prediction with [Glimmer3](https://ccb.jhu.edu/software/glimmer/)
- Identification of antibiotic resistance genes in the CARD Database [RGI](https://card.mcmaster.ca/analyze/rgi)
- Long read alignment against assembly
- Coverage analysis with [Mosdepth](https://github.com/brentp/mosdepth)
- GC Content and GC Skew
- Identification of reads that overlap the gap in the plasmid, indicating circular reads

It is created with nextflow, an application to create complex pipelines with repository integration

Requirements
------------

- Linux or Mac OS (Not tested on Windows, might work with docker)
- Java 8.x


Installation 
------------

1) Install [nextflow](https://www.nextflow.io/)

```
curl -s https://get.nextflow.io | bash 
```

This creates the `nextflow` executable in the current directory


2) Download pipeline 

You can either get the latest version by cloning this repository

```
git clone https://github.com/caspargross/plasmident
```

or download on of the [releases](https://github.com/caspargross/PlasmIdent/releases).


3) Download dependencies

All the dependencies for this pipeline can be downloaded in a [docker](https://docs.docker.com/install/) container.

```
docker pull caspargross/plasmident
```

Alternative dependency installations:

- [Singularity Container](docs/alternative_installation.md#singularity_container)
- [Use conda environment (no docker)](docs/alternative_installation.md#conda_environment)


Run Application
---------------

The pipeline requires an input file with a sample id (string) and paths for the assembly file in .fasta format and long reads in `.fastq` or `.fastq.gz`. The paths can be either relative to the input file location or absolute. In normal configuration (with docker), it is not possible to follow symbolic links. 

The file must be tab-separated and have the following format

|id |assembly|lr|
|---|--------|--|
|myid1| /path/to/assembly1.fasta|/path/to/reads1.fastq.gz|
|myid2| /path/to/assembly2.fasta|/path/to/reads2.fastq.gz|

The pipeline is started with the following command:

```
nextflow run plasmident --input read_locations.tsv

```

There are other [run profiles](doc/profiles) for specific environments.


### Optional run parameters

- `--outDir` Path of output folder
- `--seqPadding` Number of bases added at contig edges to improve long read alignment [Default: 1000]
- `--covWindow` Moving window size for coverage and gc content calculation [Default: 50]
- `--cpu` Number of threads used per process
- `--targetCov` Large read files are subsampled to this target coverage to speed up the process [Default: 50]


Results
-------

![Example_Output](doc/example_output.png)

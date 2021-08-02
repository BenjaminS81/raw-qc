#!/usr/bin/env nextflow

/*
Copyright Institut Curie 2019-2021
This software is a computer program whose purpose is to analyze high-throughput sequencing data.
You can use, modify and/ or redistribute the software under the terms of license (see the LICENSE file for more details).
The software is distributed in the hope that it will be useful, but "AS IS" WITHOUT ANY WARRANTY OF ANY KIND. 
Users are therefore encouraged to test the software's suitability as regards their requirements in conditions enabling the security of their systems and/or data. 
The fact that you are presently reading this means that you have had knowledge of the license and that you accept its terms.
*/

/*
========================================================================================
                           Raw-QC
========================================================================================
 Raw QC Pipeline.
 #### Homepage / Documentation
 https://gitlab.curie.fr/data-analysis/raw-qc
----------------------------------------------------------------------------------------
*/

def helpMessage() {
    if ("${workflow.manifest.version}" =~ /dev/ ){
       dev_mess = file("$baseDir/assets/dev_message.txt")
       log.info dev_mess.text
    }

    log.info"""
    raw-qc v${workflow.manifest.version}
    ==========================================================

    Usage:
    nextflow run main.nf --reads '*_R{1,2}.fastq.gz' -profile conda
    nextflow run main.nf --samplePlan sample_plan -profile conda

    Mandatory arguments:
      --reads [file]                Path to input data (must be surrounded with quotes)
      --samplePlan [file]           Path to sample plan input file (cannot be used with --reads)
      -profile [str]                Configuration profile to use. test / conda / singularity / cluster (see below)

    Options:
      --singleEnd [bool]            Specifies that the input is single end reads
      --trimTool [str]              Specifies adapter trimming tool ['trimgalore', 'atropos', 'fastp']. Default is 'trimgalore'

    Trimming options:
      --adapter [str]               Type of adapter to trim ['auto', 'truseq', 'nextera', 'smallrna']. Default is 'auto' for automatic detection
      --qualTrim [int]              Minimum mapping quality for trimming. Default is '20'
      --nTrim [bool]                Trim 'N' bases from either side of the reads
      --twoColour [bool]            Trimming for NextSeq/NovaSeq sequencers
      --minLen [int]                Minimum length of trimmed sequences. Default is '10'

    Presets:
      --picoV1 [bool]               Sets version 1 for the SMARTer Stranded Total RNA-Seq Kit - Pico Input kit. Only for trimgalore and fastp
      --picoV2 [bool]               Sets version 2 for the SMARTer Stranded Total RNA-Seq Kit - Pico Input kit. Only for trimgalore and fastp
      --rnaLig [bool]               Sets trimming setting for the stranded mRNA prep Ligation-Illumina. Only for trimgalore and fastp.
      --polyA [bool]                Sets trimming setting for 3'-seq analysis with polyA tail detection

    Other options:
      --outDir [dir]                The output directory where the results will be saved
      -name [str]                   Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic
      --metadata [file]             Add metadata file for multiQC report

    Skip options:
      --skipFastqcRaw [bool]        Skip FastQC on raw sequencing reads
      --skipTrimming [bool]         Skip trimming step
      --skipFastqcTrim [bool]       Skip FastQC on trimmed sequencing reads
      --skipFastqSreeen [bool]      Skip FastQScreen on trimmed sequencing reads
      --skipMultiqc [bool]          Skip MultiQC step

    =======================================================
    Available Profiles
      -profile test                 Run the test dataset
      -profile conda                Build a new conda environment before running the pipeline. Use `--condaCacheDir` to define the conda cache path
      -profile multiconda           Build a new conda environment per process before running the pipeline. Use `--condaCacheDir` to define the conda cache path
      -profile path                 Use the installation path defined for all tools. Use `--globalPath` to define the insallation path
      -profile multipath            Use the installation paths defined for each tool. Use `--globalPath` to define the insallation path
      -profile docker               Use the Docker images for each process
      -profile singularity          Use the Singularity images for each process. Use `--singularityPath` to define the insallation path
      -profile cluster              Run the workflow on the cluster, instead of locally

    """.stripIndent()
}


// Show help emssage
if (params.help){
  helpMessage()
  exit 0
}


// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if( !(workflow.runName ==~ /[a-z]+_[a-z]+/) ){
  custom_runName = workflow.runName
}

// Validate inputs 
if (params.trimTool != 'trimgalore' && params.trimTool != 'atropos' && params.trimTool != 'fastp' ){
  exit 1, "Invalid trimming tool option: ${params.trimTool}. Valid options: 'trimgalore', 'atropos', 'fastp'"
} 

if (params.adapter != 'truseq' && params.adapter != 'nextera' && params.adapter != 'smallrna' && params.adapter!= 'auto' ){
  exit 1, "Invalid adaptator seq tool option: ${params.adapter}. Valid options: 'truseq', 'nextera', 'smallrna', 'auto'"
}

if (params.adapter == 'auto' && params.trimTool == 'atropos') {
  exit 1, "Cannot use Atropos without specifying --adapter sequence."
}

if (params.adapter == 'smallrna' && !params.singleEnd){
  exit 1, "smallRNA requires singleEnd data."
}

/*
if (params.nTrim && params.trimTool == 'fastp') {
  log.warn "[raw-qc] The 'nTrim' option is not availabe for the 'fastp' trimmer. Option is ignored."
}
*/

if (params.picoV1 && params.picoV2 && params.rnaLig){
  exit 1, "Invalid SMARTer kit option at the same time for pico1 && picoV2 && rnaLig"
}

if (params.picoV1 && params.picoV2 && params.trimTool == 'atropos'){
  exit 1, "Cannot use Atropos for pico preset"
}

if (params.singleEnd && params.picoV2){
  exit 1, "Cannot use --picoV2 for single end."
}

// Stage config files
multiqcConfigCh = Channel.fromPath(params.multiqcConfig)
outputDocsCh = Channel.fromPath("$baseDir/docs/output.md")
outputDocsImagesCh = file("$baseDir/docs/images/", checkIfExists: true)
adaptorFileDetectCh = Channel.fromPath("$baseDir/assets/sequencing_adapters.fa")
adaptorFileDefaultCh = Channel.fromPath("$baseDir/assets/sequencing_adapters.fa")

// FastqScreen
Channel
  .from(params.genomes.fastqScreenGenomes)
  .set{ fastqScreenGenomeCh }

/*
 * CHANNELS
 */

if ((params.reads && params.samplePlan) || (params.readPaths && params.samplePlan)){
  exit 1, "Input reads must be defined using either '--reads' or '--samplePlan' parameter. Please choose one way"
}

if(params.samplePlan){
  if(params.singleEnd){
    Channel
      .from(file("${params.samplePlan}"))
      .splitCsv(header: false)
      .map{ row -> [ row[1], [file(row[2])]] }
      .into { readFilesFastqcCh; readFilesTrimgaloreCh; readFilesAtroposDetectCh; readFilesAtroposTrimCh; readFilesFastpCh; readFilesTrimreportCh; readFilesRawdatareportCh; readFastqscreen}
  }else{
    Channel
      .from(file("${params.samplePlan}"))
      .splitCsv(header: false)
      .map{ row -> [ row[1], [file(row[2]), file(row[3])]] }
      .into { readFilesFastqcCh; readFilesTrimgaloreCh; readFilesAtroposDetectCh; readFilesAtroposTrimCh; readFilesFastpCh; readFilesTrimreportCh; readFilesRawdatareportCh; readFastqscreen}
   }
   params.reads=false
}
else if(params.readPaths){
  if(params.singleEnd){
    Channel
      .from(params.readPaths)
      .map { row -> [ row[0], [file(row[1][0])]] }
      .ifEmpty { exit 1, "params.readPaths was empty - no input files supplied" }
      .into { readFilesFastqcCh; readFilesTrimgaloreCh; readFilesAtroposDetectCh; readFilesAtroposTrimCh; readFilesFastpCh; readFilesTrimreportCh; readFilesRawdatareportCh; readFastqscreen }
  } else {
    Channel
      .from(params.readPaths)
      .map { row -> [ row[0], [file(row[1][0]), file(row[1][1])]] }
      .ifEmpty { exit 1, "params.readPaths was empty - no input files supplied" }
      .into { readFilesFastqcCh; readFilesTrimgaloreCh; readFilesAtroposDetectCh; readFilesAtroposTrimCh; readFilesFastpCh; readFilesTrimreportCh; readFilesRawdatareportCh; readFastqscreen}
  }
} else {
    Channel
      .fromFilePairs( params.reads, size: params.singleEnd ? 1 : 2 )
      .ifEmpty { exit 1, "Cannot find any reads matching: ${params.reads}\nNB: Path needs to be enclosed in quotes!\nNB: Path requires at least one * wildcard!\nIf this is single-end data, please specify --singleEnd on the command line\
." }
      .into { readFilesFastqcCh; readFilesTrimgaloreCh; readFilesAtroposDetectCh; readFilesAtroposTrimCh; readFilesFastpCh; readFilesTrimreportCh; readFilesRawdatareportCh; readFastqscreen}
}

/*
 * Make sample plan if not available
 */

if (params.samplePlan){
  splanCh = Channel.fromPath(params.samplePlan)
}else if(params.readPaths){
  if (params.singleEnd){
    Channel
      .from(params.readPaths)
      .collectFile() {
        item -> ["sample_plan.csv", item[0] + ',' + item[0] + ',' + item[1][0] + '\n']
      }
      .set{ splanCh }
  }else{
    Channel
      .from(params.readPaths)
      .collectFile() {
        item -> ["sample_plan.csv", item[0] + ',' + item[0] + ',' + item[1][0] + ',' + item[1][1] + '\n']
      }
      .set{ splanCh }
   }
}else{
  if (params.singleEnd){
    Channel
      .fromFilePairs( params.reads, size: 1 )
      .collectFile() {
        item -> ["sample_plan.csv", item[0] + ',' + item[0] + ',' + item[1][0] + '\n']
      }
      .set { splanCh }
  }else{
    Channel
      .fromFilePairs( params.reads, size: 2 )
      .collectFile() {
        item -> ["sample_plan.csv", item[0] + ',' + item[0] + ',' + item[1][0] + ',' + item[1][1] + '\n']
      }
      .set { splanCh }
   }
}

if ( params.metadata ){
   Channel
     .fromPath( params.metadata )
     .ifEmpty { exit 1, "Metadata file not found: ${params.metadata}" }
     .set { metadataCh }
}


// Header log info
if ("${workflow.manifest.version}" =~ /dev/ ){
  dev_mess = file("$baseDir/assets/dev_message.txt")
  log.info dev_mess.text
}

log.info """=======================================================

raw-qc v${workflow.manifest.version}"
======================================================="""
def summary = [:]
summary['Pipeline Name']  = 'rawqc'
summary['Pipeline Version'] = workflow.manifest.version
summary['Run Name']     = custom_runName ?: workflow.runName
summary['Metadata']     = params.metadata
if (params.samplePlan) {
   summary['SamplePlan']   = params.samplePlan
}else{
   summary['Reads']        = params.reads
}
summary['Data Type']    = params.singleEnd ? 'Single-End' : 'Paired-End'
summary['Trimming tool']= params.trimTool
summary['Adapter']= params.adapter
summary['Min quality']= params.qualTrim
summary['Min len']= params.minLen
summary['N trim']= params.nTrim ? 'True' : 'False'
summary['Two colour']= params.twoColour ? 'True' : 'False'
if (params.picoV1) {
   summary['PicoV1'] = 'True'
}
if(params.picoV2) {
   summary['PicoV2'] = 'True'
}
if (!params.picoV1 && !params.picoV2) {
   summary['Pico'] = 'False'
}
summary['RNA Lig']=params.rnaLig ? 'True' : 'False'
summary['PolyA']= params.polyA ? 'True' : 'False'
summary['Max Memory']   = params.maxMemory
summary['Max CPUs']     = params.maxCpus
summary['Max Time']     = params.maxTime
summary['Container Engine'] = workflow.containerEngine
summary['Current home']   = "$HOME"
summary['Current user']   = "$USER"
summary['Current path']   = "$PWD"
summary['Working dir']    = workflow.workDir
summary['Output dir']     = params.outDir
summary['Config Profile'] = workflow.profile

log.info summary.collect { k,v -> "${k.padRight(15)}: $v" }.join("\n")
log.info "========================================="

/*
================================================================================
                                   Reads Trimming
================================================================================
*/


process trimGalore {
  label 'trimgalore'
  label 'medCpu'
  label 'medMem'
  publishDir "${params.outDir}/trimming", mode: 'copy'

  when:
  params.trimTool == "trimgalore" && !params.skipTrimming

  input:
  set val(name), file(reads) from readFilesTrimgaloreCh

  output:
  set val(name), file("*fastq.gz") into trimReadsTrimgaloreCh, trimgaloreReadsCh
  set val(name), file("*trimming_report.txt") into trimResultsTrimgaloreCh, reportResultsTrimgaloreCh
  file("v_trimgalore.txt") into trimgaloreVersionCh

  script:
  prefix = reads[0].toString() - ~/(_1)?(_2)?(_R1)?(_R2)?(.R1)?(.R2)?(_val_1)?(_val_2)?(\.fq)?(\.fastq)?(\.gz)?$/
  nTrim = params.nTrim ? "--trim-n" : ""
  qualTrim = params.twoColour ?  "--2colour ${params.qualTrim}" : "--quality ${params.qualTrim}"
  
  adapter = ""
  picoOpts = ""
  ligOpts = ""
  if (params.singleEnd) {
    if (params.picoV1) {
      picoOpts = "--clip_r1 3 --three_prime_clip_r2 3"
    }
    if (params.adapter == 'truseq'){
      adapter = "--adapter ${params.truseqR1}"
    }else if (params.adapter == 'nextera'){
      adapter = "--adapter ${params.nexteraR1}"
    }else if (params.adapter == 'smallrna'){
      adapter = "--adapter ${params.smallrnaR1}"
    }

    if (!params.polyA){
    """
    trim_galore --version &> v_trimgalore.txt 2>&1 || true
    trim_galore ${adapter} ${nTrim} ${qualTrim} \
                --length ${params.minLen} ${picoOpts} \
                --gzip $reads --basename ${prefix} --cores ${task.cpus}
    mv ${prefix}_trimmed.fq.gz ${prefix}_trimmed_R1.fastq.gz
    """
    }else{
    """
    trim_galore --version &> v_trimgalore.txt 2>&1 || true
    trim_galore ${adapter} ${nTrim} ${qualTrim} \
    		--length ${params.minLen} ${picoOpts} \
                --gzip $reads --basename ${prefix} --cores ${task.cpus}
    trim_galore -a "A{10}" ${qualTrim} --length ${params.minLen} \
                --gzip ${prefix}_trimmed.fq.gz --basename ${prefix}_polyA --cores ${task.cpus}
    rm ${prefix}_trimmed.fq.gz
    mv ${prefix}_polyA_trimmed_trimmed.fq.gz ${prefix}_trimmed_R1.fastq.gz
    mv ${prefix}_trimmed.fq.gz_trimming_report.txt ${prefix}_polyA_trimmingreport.txt
    """
    }
  }else {
    if (params.picoV1) {
       picoOpts = "--clip_r1 3 --three_prime_clip_r2 3"
    }
    if (params.picoV2) {
       picoOpts = "--clip_r2 3 --three_prime_clip_r1 3"
    }
    if (params.rnaLig) {
       ligOpts = "--clip_r1 1 --three_prime_clip_r2 2 --clip_r2 1 --three_prime_clip_r1 2"
    }

    if (params.adapter == 'truseq'){
      adapter ="--adapter ${params.truseqR1} --adapter2 ${params.truseqR2}"
    }else if (params.adapter == 'nextera'){
      adapter ="--adapter ${params.nexteraR1} --adapter2 ${params.nexteraR2}"
    }
    
    if (!params.polyA){
    """
    trim_galore --version &> v_trimgalore.txt 2>&1 || true
    trim_galore ${adapter} ${nTrim} ${qualTrim} \
                --length ${params.minLen} ${picoOpts} ${ligOpts} \
                --paired --gzip $reads --basename ${prefix} --cores ${task.cpus}
    mv ${prefix}_R1_val_1.fq.gz ${prefix}_trimmed_R1.fastq.gz
    mv ${prefix}_R2_val_2.fq.gz ${prefix}_trimmed_R2.fastq.gz
    """
    }else{
    """
    trim_galore --version &> v_trimgalore.txt 2>&1 || true
    trim_galore ${adapter} ${nTrim} ${qualTrim} \
                --length ${params.minLen} ${picoOpts} ${ligOpts} \
                --paired --gzip $reads --basename ${prefix} --cores ${task.cpus}

    trim_galore -a "A{10}" ${qualTrim} --length ${params.minLen} \
                 --paired --gzip ${prefix}_R1_val_1.fq.gz ${prefix}_R2_val_2.fq.gz --basename ${prefix}_polyA --cores ${task.cpus}

    mv ${prefix}_polyA_R1_val_1.fq.gz ${prefix}_trimmed_R1.fastq.gz
    mv ${prefix}_polyA_R2_val_2.fq.gz ${prefix}_trimmed_R2.fastq.gz
    mv ${prefix}_R1_val_1.fq.gz_trimming_report.txt ${prefix}_R1_polyA_trimmingreport.txt
    mv ${prefix}_R2_val_2.fq.gz_trimming_report.txt ${prefix}_R2_polyA_trimmingreport.txt
    rm ${prefix}_R1_val_1.fq.gz ${prefix}_R2_val_2.fq.gz
    """
    }
  }
   
}

process atroposTrim {
  label 'atropos'
  label 'medCpu'
  label 'medMem'
  publishDir "${params.outDir}/trimming", mode: 'copy'

  
  when:
  params.trimTool == "atropos" && !params.skipTrimming && params.adapter != ""
  
  input:
  set val(name), file(reads) from readFilesAtroposTrimCh
  file sequences from adaptorFileDefaultCh.collect()

  output:
  file("*trimming_report*") into trimResultsAtroposCh
  set val(name), file("*trimmed*fastq.gz") into trimReadsAtroposCh, atroposReadsCh
  set val(name), file("*.json") into reportResultsAtroposCh
  file("v_atropos.txt") into atroposVersionCh

  script:
  prefix = reads[0].toString() - ~/(_1)?(_2)?(_R1)?(_R2)?(.R1)?(.R2)?(_val_1)?(_val_2)?(\.fq)?(\.fastq)?(\.gz)?$/
  nTrim = params.nTrim ? "--trim-n" : ""
  nextseqTrim = params.twoColour ? "--nextseq-trim" : ""
  polyAOpts = params.polyA ? "-a A{10}" : ""

  if (params.singleEnd) {
  """
  if  [ "${params.adapter}" == "truseq" ]; then
     echo -e ">truseq_adapter_r1\n${params.truseqR1}" > ${prefix}_detect.0.fasta
  elif [ "${params.adapter}" == "nextera" ]; then
     echo -e ">nextera_adapter_r1\n${params.nexteraR1}" > ${prefix}_detect.0.fasta
  elif [ "${params.adapter}" == "smallrna" ]; then
     echo -e ">smallrna_adapter_r1\n${params.smallrnaR1}" > ${prefix}_detect.0.fasta
  fi
  atropos &> v_atropos.txt 2>&1 || true
  atropos trim -se ${reads} \
         --adapter file:${prefix}_detect.0.fasta \
         --times 3 --overlap 1 \
         --minimum-length ${params.minLen} --quality-cutoff ${params.qualTrim} \
         ${nTrim} ${nextseqTrim} ${polyAOpts} \
         --threads ${task.cpus} \
         -o ${prefix}_trimmed_R1.fastq.gz \
         --report-file ${prefix}_trimming_report \
         --report-formats txt json
  """
  } else {
  """
  if [ "${params.adapter}" == "truseq" ]; then
     echo -e ">truseq_adapter_r1\n${params.truseqR1}" > ${prefix}_detect.0.fasta
     echo -e ">truseq_adapter_r2\n${params.truseqR2}" > ${prefix}_detect.1.fasta
  elif [ "${params.adapter}" == "nextera" ]; then
     echo -e ">nextera_adapter_r1\n${params.nexteraR1}" > ${prefix}_detect.0.fasta
     echo -e ">nextera_adapter_r2\n${params.nexteraR2}" > ${prefix}_detect.1.fasta
  fi
  atropos &> v_atropos.txt 2>&1 || true
  atropos -pe1 ${reads[0]} -pe2 ${reads[1]} \
         --adapter file:${prefix}_detect.0.fasta -A file:${prefix}_detect.1.fasta \
         -o ${prefix}_trimmed_R1.fastq.gz -p ${prefix}_trimmed_R2.fastq.gz  \
         --times 3 --overlap 1 \
         --minimum-length ${params.minLen} --quality-cutoff ${params.qualTrim} \
         ${nTrim} ${nextseqTrim} ${polyAOpts} \
         --threads ${task.cpus} \
         --report-file ${prefix}_trimming_report \
         --report-formats txt json
  """
  }
}

process fastp {
  label 'fastp'
  label 'medCpu'
  label 'medMem'

  publishDir "${params.outDir}/trimming", mode: 'copy'


  when:
  params.trimTool == "fastp" && !params.skipTrimming
  
  input:
  set val(name), file(reads) from readFilesFastpCh
  
  output:
  set val(name), file("*trimmed*fastq.gz") into trimReadsFastpCh, fastpReadsCh
  set val(name), file("*.{json,log}") into trimResultsFastpCh, reportResultsFastpCh
  file("v_fastp.txt") into fastpVersionCh

  script:
  prefix = reads[0].toString() - ~/(_1)?(_2)?(_R1)?(_R2)?(.R1)?(.R2)?(_val_1)?(_val_2)?(\.fq)?(\.fastq)?(\.gz)?$/
  nextseqTrim = params.twoColour ? "--trim_poly_g" : "--disable_trim_poly_g"
  nTrim = params.nTrim ? "" : "--n_base_limit 0"
  picoOpts = ""
  polyAOpts = params.polyA ? "--trim_poly_x" : ""
  adapter = ""

  if (params.singleEnd) {
    // we don't usually have pico_version2 for single-end.
    if (params.picoV1) {
       picoOpts = "--trim_front1 3 --trim_tail1 3"
    } 

    if (params.adapter == 'truseq'){
      adapter ="--adapter_sequence ${params.truseqR1}"
    }else if (params.adapter == 'nextera'){
      adapter ="--adapter_sequence ${params.nexteraR1}"
    }else if (params.adapter == 'smallrna'){
      adapter ="--adapter_sequence ${params.smallrnaR1}"
    }
    """
    fastp --version &> v_fastp.txt 2>&1 || true
    fastp ${adapter} \
    --qualified_quality_phred ${params.qualTrim} \
    ${nextseqTrim} ${picoOpts} ${polyAOpts} \
    ${nTrim} \
    --length_required ${params.minLen} \
    -i ${reads} -o ${prefix}_trimmed_R1.fastq.gz \
    -j ${prefix}.fastp.json -h ${prefix}.fastp.html\
    --thread ${task.cpus} 2> ${prefix}_fasp.log
    """
  } else {
    if (params.picoV1) {
       picoOpts = "--trim_front1 3 --trim_tail2 3"
    }
    if (params.picoV2) {
       picoOpts = "--trim_front2 3 --trim_tail1 3"
    }

    if (params.rnaLig) {
       ligOpts = "--trim_front1 1 --trim_tail2 2 --trim_front2 1 --trim_tail1 2"
    }

    if (params.adapter == 'truseq'){
      adapter ="--adapter_sequence ${params.truseqR1} --adapter_sequence_r2 ${params.truseqR2}"
    }
    else if (params.adapter == 'nextera'){
      adapter ="--adapter_sequence ${params.nexteraR1} --adapter_sequence_r2 ${params.nexteraR2}"
    }
    """
    fastp --version &> v_fastp.txt 2>&1 || true
    fastp ${adapter} \
    --qualified_quality_phred ${params.qualTrim} \
    ${nextseqTrim} ${picoOpts} ${polyAOpts} ${ligOpts} \
    ${nTrim} \
    --length_required ${params.minLen} \
    -i ${reads[0]} -I ${reads[1]} -o ${prefix}_trimmed_R1.fastq.gz -O ${prefix}_trimmed_R2.fastq.gz \
    --detect_adapter_for_pe -j ${prefix}.fastp.json -h ${prefix}.fastp.html \
    --thread ${task.cpus} 2> ${prefix}_fasp.log
    """
  }
}

if (!params.skipTrimming){
  if(params.trimTool == "atropos"){
    trimReadsCh = trimReadsAtroposCh
    trimReportsCh = reportResultsAtroposCh
  }else if (params.trimTool == "trimgalore"){
    trimReadsCh = trimReadsTrimgaloreCh
    trimReportsCh = reportResultsTrimgaloreCh
  }else if (params.trimTool == "fastp"){
    trimReadsCh = trimReadsFastpCh
    trimReportsCh = reportResultsFastpCh
  }
}

/*
================================================================================
                                   Make Reports
================================================================================
*/

if (!params.skipTrimming){

  process makeReport {
    label 'python'
    label 'lowCpu'
    label 'extraMem'
    publishDir "${params.outDir}/makeReport", mode: 'copy'

    input:
    set val(name), file(reads), file(trims), file(reports) from readFilesTrimreportCh.join(trimReadsCh).join(trimReportsCh)

    output:
    file '*_Basic_Metrics.trim.txt' into trimReportCh
    file "*_Adaptor_seq.trim.txt" into trimAdaptorCh

    script:
    prefix = reads[0].toString() - ~/(_1)?(_2)?(_R1)?(_R2)?(.R1)?(.R2)?(_val_1)?(_val_2)?(\.fq)?(\.fastq)?(\.gz)?$/
    isPE = params.singleEnd ? 0 : 1

    if (params.singleEnd) {
      if(params.trimTool == "fastp"){
      """
      create_subset_data.sh ${isPE} ${prefix} ${reads} ${trims}
      trimming_report.py --l ${prefix}_fasp.log --tr1 ${reports[0]} --r1 subset_${prefix}.R1.fastq.gz --t1 subset_${prefix}_trims.R1.fastq.gz --u ${params.trimTool} --b ${name} --o ${prefix}
      """
      } else {
      """
      create_subset_data.sh ${isPE} ${prefix} ${reads} ${trims}
      trimming_report.py --tr1 ${reports} --r1 subset_${prefix}.R1.fastq.gz --t1 subset_${prefix}_trims.R1.fastq.gz --u ${params.trimTool} --b ${name} --o ${prefix}
      """
      }
    } else {
      if(params.trimTool == "trimgalore"){
      """
      create_subset_data.sh ${isPE} ${prefix} ${reads} ${trims}
      trimming_report.py --tr1 ${reports[0]} --tr2 ${reports[1]} --r1 subset_${prefix}.R1.fastq.gz --r2 subset_${prefix}.R2.fastq.gz --t1 subset_${prefix}_trims.R1.fastq.gz --t2 subset_${prefix}_trims.R2.fastq.gz --u ${params.trimTool} --b ${name} --o ${prefix}
      """
      } else if (params.trimTool == "fastp"){
      """
      create_subset_data.sh ${isPE} ${prefix} ${reads} ${trims}
      trimming_report.py --l ${prefix}_fasp.log --tr1 ${reports[0]} --r1 subset_${prefix}.R1.fastq.gz --r2 subset_${prefix}.R2.fastq.gz --t1 subset_${prefix}_trims.R1.fastq.gz --t2 subset_${prefix}_trims.R2.fastq.gz --u ${params.trimTool} --b ${name} --o ${prefix}
      """
      } else {
      """
      create_subset_data.sh ${isPE} ${prefix} ${reads} ${trims}
      trimming_report.py --tr1 ${reports[0]} --r1 subset_${prefix}.R1.fastq.gz --r2 subset_${prefix}.R2.fastq.gz --t1 subset_${prefix}_trims.R1.fastq.gz --t2 subset_${prefix}_trims.R2.fastq.gz --u ${params.trimTool} --b ${name} --o ${prefix}
      """
      }
    }
  }
}else{

  trimAdaptorCh = Channel.empty()

  process makeReport4RawData {
    label 'python'
    label 'medCpu'
    label 'medMem'
    publishDir "${params.outDir}/makeReport", mode: 'copy'

    input:
    set val(name), file(reads) from readFilesRawdatareportCh

    output:
    file '*_Basic_Metrics_rawdata.txt' into trimReportCh

    script:
    prefix = reads[0].toString() - ~/(_1)?(_2)?(_R1)?(_R2)?(.R1)?(.R2)?(_val_1)?(_val_2)?(\.fq)?(\.fastq)?(\.gz)?$/
    if (params.singleEnd) {
    """
    rawdata_stat_report.py --r1 ${reads} --b ${name} --o ${prefix}
    """
    } else {
    """
    rawdata_stat_report.py --r1 ${reads[0]} --r2 ${reads[1]} --b ${name} --o ${prefix}
    """
   }
 }
}


/*
================================================================================
   QC on trim data [FastQC]
================================================================================
*/


if (!params.skipTrimming){
  if (params.trimTool == "atropos"){
    atroposReadsCh.into{fastqcTrimReadsCh; fastqScreenReadsCh} 
  }else if (params.trimTool == "trimgalore"){
    trimgaloreReadsCh.into{fastqcTrimReadsCh; fastqScreenReadsCh}
  }else{
    fastpReadsCh.into{fastqcTrimReadsCh; fastqScreenReadsCh}
  }
}else{
  fastqScreenReadsCh = readFastqscreenCh  
  fastqcTrimReadsCh = Channel.empty()
}


process fastqcTrimmed {
  label 'fastqc'
  label 'lowCpu'
  label 'minMem'
  publishDir "${params.outDir}/fastqc_trimmed", mode: 'copy'

  input:
  set val(name), file(reads) from fastqcTrimReadsCh

  output:
  file "*_fastqc.{zip,html}" into fastqcAfterTrimResultsCh
  file("v_fastqc.txt") into fastqcTrimmedVersionCh

  script:
  """
  fastqc -q $reads -t ${task.cpus}
  fastqc --version &> v_fastqc.txt 2>&1 || true
  """
}

if (params.skipFastqcTrim || params.skipTrimming){
  fastqcAfterTrimResultsCh = Channel.empty()
}

/*
================================================================================
                                     FastqScreen
================================================================================
*/

process makeFastqScreenGenomeConfig {
  label 'lowCpu'
  label 'minMem'
  publishDir "${params.outDir}/fastq_screen", mode: 'copy'
     
  when:
  !params.skipFastqScreen

  input:
  val(fastqScreenGenome) from fastqScreenGenomeCh

  output:
  file(outputFile) into fastqScreenConfigCh

  script:
  outputFile = 'fastq_screen_databases.config'

  String result = ''
  for (Map.Entry entry: fastqScreenGenome.entrySet()) {
    result += """
    echo -e 'DATABASE\\t${entry.key}\\t${entry.value}' >> ${outputFile}"""
  }
  return result
}

process fastqScreen {
  label 'fastqScreen'
  label 'medCpu'
  label 'medMem'
  publishDir "${params.outDir}/fastq_screen", mode: 'copy'

  when:
  !params.skipFastqScreen

  input:
  file fastqScreenGenomes from Channel.fromList(params.genomes.fastqScreenGenomes.values().collect{file(it)})
  set val(name), file(reads) from fastqScreenReadsCh
  file fastq_screen_config from fastqScreenConfigCh.collect()

  output:
  file("*_screen.txt") into fastqScreenTxtCh
  file("*_screen.html") into fastqScreenHtml
  file("*tagged_filter.fastq.gz") into nohitsFastqCh
  file("v_fastqscreen.txt") into fastqscreenVersionCh

  script:
  """
  fastq_screen --force --subset 200000 --threads ${task.cpus} --conf ${fastq_screen_config} --nohits --aligner bowtie2 ${reads}
  fastq_screen --version &> v_fastqscreen.txt 2>&1 || true
  """
}


// Workflows
// QC : check actqc
include { qcFlow } from './nf-modules/local/subworkflow/qc'

// Alignment on reference genome
// include { mappingFlow } from './nf-modules/common/subworkflow/mapping' addParams( alignerr: params.aligner, bwa_options: bwa_options, bowtie2_options: bowtie2_options, star_options: star_options )
include { mappingFlow } from './nf-modules/local/subworkflow/mapping'

// Processes
include { getSoftwareVersions } from './nf-modules/local/process/getSoftwareVersions'
include { workflowSummaryMqc } from './nf-modules/local/process/workflowSummaryMqc'
include { multiqc } from './nf-modules/local/process/multiqc'
include { outputDocumentation } from './nf-modules/local/process/outputDocumentation'

workflow {
    main:

      // subroutines
      outputDocumentation(
       outputDocsCh,
       outputDocsImagesCh
      )

      // QC : check factqc
      qcFlow(
       rawReads
      )


      // MultiQC
      getSoftwareVersions(
        trimgaloreVersionCh.first().ifEmpty([]),
        fastpVersionCh.first().ifEmpty([]),
        from atroposVersionCh.first().ifEmpty([]),
        fastqscreenVersionCh.first().ifEmpty([]),
        qcFlow.out.fastqcVersionCh.mix(fastqcTrimmedVersionCh).first().ifEmpty([])
      )

      workflowSummaryMqc(
        summary
      )

      multiqc(
        customRunName,
        splanCh.collect(),
        metadataCh.ifEmpty([]),
        multiqcConfigCh, 
        qcFlow.out.fastqcResultsCh.collect().ifEmpty([]),
        trimResultsAtroposCh.collect().ifEmpty([]),
        trimResultsTrimgaloreCh.map{items->items[1]}.collect().ifEmpty([]),
        trimResultsFastpCh.map{items->items[1]}.collect().ifEmpty([]),
        fastqcAfterTrimResultsCh.collect().ifEmpty([]),
        fastqScreenTxtCh.collect().ifEmpty([]),
        trimReportCh.collect().ifEmpty([]),
        trimAdaptorCh.collect().ifEmpty([]),
        softwareVersionsYamlCh.collect(),
        workflowSummaryYamlCh.collect()
      )
}

/* Creates a file at the end of workflow execution */
workflow.onComplete {
  /*pipeline_report.html*/
  def report_fields = [:]
  report_fields['version'] = workflow.manifest.version
  report_fields['runName'] = customRunName ?: workflow.runName
  report_fields['success'] = workflow.success
  report_fields['dateComplete'] = workflow.complete
  report_fields['duration'] = workflow.duration
  report_fields['exitStatus'] = workflow.exitStatus
  report_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
  report_fields['errorReport'] = (workflow.errorReport ?: 'None')
  report_fields['commandLine'] = workflow.commandLine
  report_fields['projectDir'] = workflow.projectDir
  report_fields['summary'] = summary
  report_fields['summary']['Date Started'] = workflow.start
  report_fields['summary']['Date Completed'] = workflow.complete
  report_fields['summary']['Pipeline script file path'] = workflow.scriptFile
  report_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
  if(workflow.repository) report_fields['summary']['Pipeline repository Git URL'] = workflow.repository
  if(workflow.commitId) report_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
  if(workflow.revision) report_fields['summary']['Pipeline Git branch/tag'] = workflow.revision

  // Render the TXT template
  def engine = new groovy.text.GStringTemplateEngine()
  def tf = new File("$baseDir/assets/onCompleteTemplate.txt")
  def txt_template = engine.createTemplate(tf).make(report_fields)
  def report_txt = txt_template.toString()

  // Render the HTML template
  def hf = new File("$baseDir/assets/onCompleteTemplate.html")
  def html_template = engine.createTemplate(hf).make(report_fields)
  def report_html = html_template.toString()
  // Write summary e-mail HTML to a file
  def output_d = new File( "${params.summaryDir}/" )
  if( !output_d.exists() ) {
    output_d.mkdirs()
  }
  def output_hf = new File( output_d, "pipelineReport.html" )
  output_hf.withWriter { w -> w << report_html }
  def output_tf = new File( output_d, "pipelineReport.txt" )
  output_tf.withWriter { w -> w << report_txt }
  /*oncomplete file*/
  File woc = new File("${params.outDir}/workflowOnComplete.txt")
  Map endSummary = [:]
  endSummary['Completed on'] = workflow.complete
  endSummary['Duration']     = workflow.duration
  endSummary['Success']      = workflow.success
  endSummary['exit status']  = workflow.exitStatus
  endSummary['Error report'] = workflow.errorReport ?: '-'
  String endWfSummary = endSummary.collect { k,v -> "${k.padRight(30, '.')}: $v" }.join("\n")
  println endWfSummary
  String execInfo = "Execution summary\n${endWfSummary}\n"
  woc.write(execInfo)
 
  /*final logs*/
  if(workflow.success){
    log.info "[rawqc] Pipeline Complete"
  }else{
    log.info "[rawqc] FAILED: $workflow.runName"
  } 
}



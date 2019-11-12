#!/usr/bin/env nextflow

/*
Copyright Institut Curie 2019
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
      --reads 'READS'               Path to input data (must be surrounded with quotes)
      --samplePlan 'SAMPLEPLAN'     Path to sample plan input file (cannot be used with --reads)
      -profile PROFILE              Configuration profile to use. test / conda / singularity / cluster (see below)

    Options:
      --singleEnd                   Specifies that the input is single end reads
      --trimtool 'TOOL'             Specifies adapter trimming tool ['trimgalore', 'atropos', 'fastp']. Default is 'trimgalore'

    Trimming options:
      --adapter 'ADAPTER'           Type of adapter to trim ['auto', 'truseq', 'nextera', 'smallrna']. Default is 'auto' for automatic detection
      --qualtrim QUAL               Minimum mapping quality for trimming. Default is '20'
      --ntrim                       Trim 'N' bases from either side of the reads
      --two_colour                  Trimming for NextSeq/NovaSeq sequencers
      --minlen LEN                  Minimum length of trimmed sequences. Default is '10'

    Presets:
      --pico_v1                     Sets version 1 for the SMARTer Stranded Total RNA-Seq Kit - Pico Input kit. Only for trimgalore and fastp
      --pico_v2                     Sets version 2 for the SMARTer Stranded Total RNA-Seq Kit - Pico Input kit. Only for trimgalore and fastp
      --polyA                       Sets trimming setting for 3'-seq analysis with polyA tail detection

    Other options:
      --outdir 'PATH'               The output directory where the results will be saved
      -name 'NAME'                  Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic
      --metadata 'FILE'             Add metadata file for multiQC report

    Skip options:
      --skip_fastqc_raw             Skip FastQC on raw sequencing reads
      --skip_trimming               Skip trimming step
      --skip_fastqc_trim            Skip FastQC on trimmed sequencing reads
      --skip_multiqc                Skip MultiQC step

    =======================================================
    Available Profiles

      -profile test                Set up the test dataset
      -profile conda               Build a new conda environment before running the pipeline
      -profile condaPath           Use a pre-build conda environment already installed on our cluster
      -profile singularity         Use the Singularity images for each process
      -profile cluster             Run the workflow on the cluster, instead of locally

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
if (params.trimtool != 'trimgalore' && params.trimtool != 'atropos' && params.trimtool != 'fastp' ){
    exit 1, "Invalid trimming tool option: ${params.trimtool}. Valid options: 'trimgalore', 'atropos', 'fastp'"
} 

if (params.adapter != 'truseq' && params.adapter != 'nextera' && params.adapter != 'smallrna' && params.adapter!= 'auto' ){
    exit 1, "Invalid adaptator seq tool option: ${params.adapter}. Valid options: 'truseq', 'nextera', 'smallrna', 'auto'"
}

if (params.adapter == 'auto' && params.trimtool == 'atropos') {
   exit 1, "Cannot use Atropos without specifying --adapter sequence."
}

if (params.adapter == 'smallrna' && !params.singleEnd){
    exit 1, "smallRNA requires singleEnd data."
}

if (params.ntrim && params.trimtool == 'fastp') {
  log.warn "[raw-qc] The 'ntrim' option is not availabe for the 'fastp' trimmer. Option is ignored."
}

if (params.pico_v1 && params.pico_v2){
    exit 1, "Invalid SMARTer kit option at the same time for pico_v1 && pico_v2"
}

if (params.pico_v1 && params.pico_v2 && params.trimtool == 'atropos'){
    exit 1, "Cannot use Atropos for pico preset"
}

if (params.singleEnd && params.pico_v2){
   exit 1, "Cannot use --pico_v2 for single end."
}



// Stage config files
ch_multiqc_config = Channel.fromPath(params.multiqc_config)
ch_output_docs = Channel.fromPath("$baseDir/docs/output.md")
ch_adaptor_file_detect = Channel.fromPath("$baseDir/assets/sequencing_adapters.fa")
ch_adaptor_file_defult = Channel.fromPath("$baseDir/assets/sequencing_adapters.fa")

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
         .into { read_files_fastqc; read_files_trimgalore; read_files_atropos_detect; read_files_atropos_trim; read_files_fastp; read_files_trimreport }
   }else{
      Channel
         .from(file("${params.samplePlan}"))
         .splitCsv(header: false)
         .map{ row -> [ row[1], [file(row[2]), file(row[3])]] }
         .into { read_files_fastqc; read_files_trimgalore; read_files_atropos_detect; read_files_atropos_trim; read_files_fastp; read_files_trimreport }
   }
   params.reads=false
}
else if(params.readPaths){
    if(params.singleEnd){
        Channel
            .from(params.readPaths)
            .map { row -> [ row[0], [file(row[1][0])]] }
            .ifEmpty { exit 1, "params.readPaths was empty - no input files supplied" }
            .into { read_files_fastqc; read_files_trimgalore; read_files_atropos_detect; read_files_atropos_trim; read_files_fastp; read_files_trimreport }
    } else {
        Channel
            .from(params.readPaths)
            .map { row -> [ row[0], [file(row[1][0]), file(row[1][1])]] }
            .ifEmpty { exit 1, "params.readPaths was empty - no input files supplied" }
            .into { read_files_fastqc; read_files_trimgalore; read_files_atropos_detect; read_files_atropos_trim; read_files_fastp; read_files_trimreport }
    }
} else {
    Channel
        .fromFilePairs( params.reads, size: params.singleEnd ? 1 : 2 )
        .ifEmpty { exit 1, "Cannot find any reads matching: ${params.reads}\nNB: Path needs to be enclosed in quotes!\nNB: Path requires at least one * wildcard!\nIf this is single-end data, please specify --singleEnd on the command line\
." }
        .into { read_files_fastqc; read_files_trimgalore; read_files_atropos_detect; read_files_atropos_trim; read_files_fastp; read_files_trimreport }
}

/*
 * Make sample plan if not available
 */

if (params.samplePlan){
  ch_splan = Channel.fromPath(params.samplePlan)
}else if(params.readPaths){
  if (params.singleEnd){
    Channel
       .from(params.readPaths)
       .collectFile() {
         item -> ["sample_plan.csv", item[0] + ',' + item[0] + ',' + item[1][0] + '\n']
        }
       .set{ ch_splan }
  }else{
     Channel
       .from(params.readPaths)
       .collectFile() {
         item -> ["sample_plan.csv", item[0] + ',' + item[0] + ',' + item[1][0] + ',' + item[1][1] + '\n']
        }
       .set{ ch_splan }
  }
}else{
  if (params.singleEnd){
    Channel
       .fromFilePairs( params.reads, size: 1 )
       .collectFile() {
          item -> ["sample_plan.csv", item[0] + ',' + item[0] + ',' + item[1][0] + '\n']
       }
       .set { ch_splan }
  }else{
    Channel
       .fromFilePairs( params.reads, size: 2 )
       .collectFile() {
          item -> ["sample_plan.csv", item[0] + ',' + item[0] + ',' + item[1][0] + ',' + item[1][1] + '\n']
       }
       .set { ch_splan }
   }
}

if ( params.metadata ){
   Channel
       .fromPath( params.metadata )
       .ifEmpty { exit 1, "Metadata file not found: ${params.metadata}" }
       .set { ch_metadata }
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
summary['Trimming tool']= params.trimtool
summary['Adapter']= params.adapter
summary['Min quality']= params.qualtrim
summary['Min len']= params.minlen
summary['N trim']= params.ntrim ? 'True' : 'False'
summary['Two colour']= params.two_colour ? 'True' : 'False'
if (params.pico_v1) {
   summary['Pico_v1'] = 'True'
}
if(params.pico_v2) {
   summary['Pico_v2'] = 'True'
}
if (!params.pico_v1 && !params.pico_v2) {
   summary['Pico'] = 'False'
}
summary['PolyA']= params.polyA ? 'True' : 'False'
summary['Max Memory']   = params.max_memory
summary['Max CPUs']     = params.max_cpus
summary['Max Time']     = params.max_time
summary['Container Engine'] = workflow.containerEngine
summary['Current home']   = "$HOME"
summary['Current user']   = "$USER"
summary['Current path']   = "$PWD"
summary['Working dir']    = workflow.workDir
summary['Output dir']     = params.outdir
summary['Config Profile'] = workflow.profile

if(params.email) summary['E-mail Address'] = params.email
log.info summary.collect { k,v -> "${k.padRight(15)}: $v" }.join("\n")
log.info "========================================="

/* Creates a file at the end of workflow execution */
workflow.onComplete {
  File woc = new File("${params.outdir}/raw-qc.workflow.oncomplete.txt")
  Map endSummary = [:]
  endSummary['Completed on'] = workflow.complete
  endSummary['Duration']     = workflow.duration
  endSummary['Success']      = workflow.success
  endSummary['exit status']  = workflow.exitStatus
  endSummary['Error report'] = workflow.errorReport ?: '-'
  String endWfSummary = endSummary.collect { k,v -> "${k.padRight(30, '.')}: $v" }.join("\n")
  println endWfSummary
  String execInfo = "Summary\n${endWfSummary}\n"
  woc.write(execInfo)
}

/*
 * STEP 1 - FastQC
*/


process fastqc {
    tag "$name (raw)"
    publishDir "${params.outdir}/fastqc", mode: 'copy',
        saveAs: {filename -> filename.indexOf(".zip") > 0 ? "zips/$filename" : "$filename"}

    when:
    !params.skip_fastqc_raw

    input:
    set val(name), file(reads) from read_files_fastqc

    output:
    file "*_fastqc.{zip,html}" into fastqc_results

    script:
    """
    fastqc -q $reads -t ${task.cpus}
    """
}


/*
 * STEP 2 - Reads Trimming
*/

process trimGalore {
  tag "$name" 
  publishDir "${params.outdir}/trimming", mode: 'copy',
              saveAs: {filename -> filename.indexOf(".log") > 0 ? "logs/$filename" : "$filename"}
  when:
  params.trimtool == "trimgalore" && !params.skip_trimming

  input:
  set val(name), file(reads) from read_files_trimgalore

  output:
  file "*fq.gz" into trim_reads_trimgalore, fastqc_trimgalore_reads
  file "*trimming_report.txt" into trim_results_trimgalore, report_results_trimgalore

  script:
  prefix = reads[0].toString() - ~/(_1)?(_2)?(_R1)?(_R2)?(.R1)?(.R2)?(_val_1)?(_val_2)?(\.fq)?(\.fastq)?(\.gz)?$/
  ntrim = params.ntrim ? "--trim-n" : ""
  qual_trim = params.two_colour ?  "--2colour ${params.qualtrim}" : "--quality ${params.qualtrim}"
  adapter = ""
  pico_opts = ""
  if (params.singleEnd) {
    println params.pico_v1
    if (params.pico_v1) {
       pico_opts = "--clip_r1 3 --three_prime_clip_r2 3"
    }

    if (params.adapter == 'truseq'){
      adapter = "--adapter ${params.truseq_r1}"
    }else if (params.adapter == 'nextera'){
      adapter = "--adapter ${params.nextera_r1}"
    }else if (params.adapter == 'smallrna'){
      adapter = "--adapter ${params.smallrna_r1}"
    }

    if (!params.polyA){
    """
    trim_galore ${adapter} ${ntrim} ${qual_trim} \
                --length ${params.minlen} ${pico_opts} \
                --gzip $reads --basename ${prefix} --cores ${task.cpus}
    """
    }else{
    """
    trim_galore ${adapter} ${ntrim} ${qual_trim} \
    		--length ${params.minlen} ${pico_opts} \
                --gzip $reads --basename ${prefix} --cores ${task.cpus}
    trim_galore -a "A{10}" ${qual_trim} --length ${params.minlen} \
                --gzip ${prefix}_trimmed.fq.gz --basename ${prefix}_polyA --cores ${task.cpus}
    rm ${prefix}_trimmed.fq.gz
    mv ${prefix}_polyA_trimmed_trimmed.fq.gz ${prefix}_polyA_trimmed.fq.gz
    mv ${reads}_trimming_report.txt ${prefix}_trimming_report.txt
    mv ${prefix}_trimmed.fq.gz_trimming_report.txt ${prefix}_polyA_trimming_report.txt
    """
    }
  }else {
    if (params.pico_v1) {
       pico_opts = "--clip_r1 3 --three_prime_clip_r2 3"
    }
    if (params.pico_v2) {
       pico_opts = "--clip_r2 3 --three_prime_clip_r1 3"
    }

    if (params.adapter == 'truseq'){
      adapter ="--adapter ${params.truseq_r1} --adapter2 ${params.truseq_r2}"
    }else if (params.adapter == 'nextera'){
      adapter ="--adapter ${params.nextera_r1} --adapter2 ${params.nextera_r2}"
    }
    
    if (!params.polyA){
    """
    trim_galore ${adapter} ${ntrim} ${qual_trim} \
                --length ${params.minlen} ${pico_opts} \
                --paired --gzip $reads --basename ${prefix} --cores ${task.cpus}
    mv ${prefix}_R1_val_1.fq.gz ${prefix}_R1_trimmed.fq.gz
    mv ${prefix}_R2_val_2.fq.gz ${prefix}_R2_trimmed.fq.gz
    """
    }else{
    """
    trim_galore ${adapter} ${ntrim} ${qual_trim} \
                --length ${params.minlen} ${pico_opts} \
                --paired --gzip $reads --basename ${prefix} --cores ${task.cpus}
    trim_galore -a "A{10}" ${qual_trim} --length ${params.minlen} \
      	      	--paired --gzip ${prefix}_R1_val_1.fq.gz ${prefix}_R2_val_2.fq.gz --basename ${prefix}_polyA --cores ${task.cpus}
    mv ${prefix}_polyA_R1_val_1.fq.gz ${prefix}_R1_trimmed_polyA.fq.gz
    mv ${prefix}_polyA_R2_val_2.fq.gz ${prefix}_R2_trimmed_polyA.fq.gz
    mv ${reads[0]}_trimming_report.txt ${prefix}_R1_trimming_report.txt
    mv ${reads[1]}_trimming_report.txt ${prefix}_R2_trimming_report.txt
    mv ${prefix}_R1_val_1.fq.gz_trimming_report.txt ${prefix}_R1_polyA_trimming_report.txt
    mv ${prefix}_R2_val_2.fq.gz_trimming_report.txt ${prefix}_R2_polyA_trimming_report.txt
    rm ${prefix}_R1_val_1.fq.gz ${prefix}_R2_val_2.fq.gz
    """
    }
  }
}


process atroposTrim {
  publishDir "${params.outdir}/trimming", mode: 'copy',
              saveAs: {filename -> filename.indexOf(".log") > 0 ? "logs/$filename" : "$filename"}
  
  when:
  params.trimtool == "atropos" && !params.skip_trimming && params.adapter != ""
  
  input:
  set val(name), file(reads) from read_files_atropos_trim
  file sequences from ch_adaptor_file_defult.collect()

  output:
  file "*trimming_report*" into trim_results_atropos
  file "*_trimmed.fq.gz" into trim_reads_atropos, fastqc_atropos_reads
  file "*.json" into report_results_atropos

   script:
   prefix = reads[0].toString() - ~/(_1)?(_2)?(_R1)?(_R2)?(.R1)?(.R2)?(_val_1)?(_val_2)?(\.fq)?(\.fastq)?(\.gz)?$/
   ntrim = params.ntrim ? "--trim-n" : ""
   nextseq_trim = params.two_colour ? "--nextseq-trim" : ""
   polyA_opts = params.polyA ? "-a A{10}" : ""

   if (params.singleEnd) {
   """
   if  [ "${params.adapter}" == "truseq" ]; then
      echo -e ">truseq_adapter_r1\n${params.truseq_r1}" > ${prefix}_detect.0.fasta
   elif [ "${params.adapter}" == "nextera" ]; then
      echo -e ">nextera_adapter_r1\n${params.nextera_r1}" > ${prefix}_detect.0.fasta
   elif [ "${params.adapter}" == "smallrna" ]; then
      echo -e ">smallrna_adapter_r1\n${params.smallrna_r1}" > ${prefix}_detect.0.fasta
   fi
   atropos trim -se ${reads} \
         --adapter file:${prefix}_detect.0.fasta \
         --times 3 --overlap 1 \
         --minimum-length ${params.minlen} --quality-cutoff ${params.qualtrim} \
         ${ntrim} ${nextseq_trim} ${polyA_opts} \
         --threads ${task.cpus} \
         -o ${prefix}_trimmed.fq.gz \
         --report-file ${prefix}_trimming_report \
         --report-formats txt yaml json
   """
   } else {
   """
   if [ "${params.adapter}" == "truseq" ]; then
      echo -e ">truseq_adapter_r1\n${params.truseq_r1}" > ${prefix}_detect.0.fasta
      echo -e ">truseq_adapter_r2\n${params.truseq_r2}" > ${prefix}_detect.1.fasta
   elif [ "${params.adapter}" == "nextera" ]; then
      echo -e ">nextera_adapter_r1\n${params.nextera_r1}" > ${prefix}_detect.0.fasta
      echo -e ">nextera_adapter_r2\n${params.nextera_r2}" > ${prefix}_detect.1.fasta
   fi
   atropos -pe1 ${reads[0]} -pe2 ${reads[1]} \
         --adapter file:${prefix}_detect.0.fasta -A file:${prefix}_detect.1.fasta \
         -o ${prefix}_R1_trimmed.fq.gz -p ${prefix}_R2_trimmed.fq.gz  \
         --times 3 --overlap 1 \
         --minimum-length ${params.minlen} --quality-cutoff ${params.qualtrim} \
         ${ntrim} ${nextseq_trim} ${polyA_opts} \
         --threads ${task.cpus} \
         --report-file ${prefix}_trimming_report \
         --report-formats txt yaml json
   """
   }
}

process fastp {
  publishDir "${params.outdir}/trimming", mode: 'copy',
              saveAs: {filename -> filename.indexOf(".log") > 0 ? "logs/$filename" : "$filename"}

  when:
  params.trimtool == "fastp" && !params.skip_trimming
  
  input:
  set val(name), file(reads) from read_files_fastp
  
  output:
  file "*_trimmed.fastq.gz" into trim_reads_fastp, fastqc_fastp_reads
  file "*.json" into trim_results_fastp, report_results_fastp
  file "*.log" into trim_log_fastp

  script:
  prefix = reads[0].toString() - ~/(_1)?(_2)?(_R1)?(_R2)?(.R1)?(.R2)?(_val_1)?(_val_2)?(\.fq)?(\.fastq)?(\.gz)?$/
  nextseq_trim = params.two_colour ? "--trim_poly_g" : "--disable_trim_poly_g"
  ntrim = params.ntrim ? "" : "--n_base_limit 0"
  pico_opts = ""
  polyA_opts = params.polyA ? "--trim_poly_x" : ""
  adapter = ""

  if (params.singleEnd) {
    // we don't usually have pico_version2 for single-end.
    if (params.pico_v1) {
       pico_opts = "--trim_front1 3 --trim_tail1 3"
    } 

    if (params.adapter == 'truseq'){
      adapter ="--adapter_sequence ${params.truseq_r1}"
    }else if (params.adapter == 'nextera'){
      adapter ="--adapter_sequence ${params.nextera_r1}"
    }else if (params.adapter == 'smallrna'){
      adapter ="--adapter_sequence ${params.smallrna_r1}"
    }
    """
    fastp ${adapter} \
    --qualified_quality_phred ${params.qualtrim} \
    ${nextseq_trim} ${pico_opts} ${polyA_opts} \
    ${ntrim} \
    --length_required ${params.minlen} \
    -i ${reads} -o ${prefix}_trimmed.fastq.gz \
    -j ${prefix}.fastp.json -h ${prefix}.fastp.html\
    --thread ${task.cpus} 2> ${prefix}_fasp.log
    """
  } else {
    if (params.pico_v1) {
       pico_opts = "--trim_front1 3 --trim_tail2 3"
    }
    if (params.pico_v2) {
       pico_opts = "--trim_front2 3 --trim_tail1 3"
    }

    if (params.adapter == 'truseq'){
      adapter ="--adapter_sequence ${params.truseq_r1} --adapter_sequence_r2 ${params.truseq_r2}"
    }
    else if (params.adapter == 'nextera'){
      adapter ="--adapter_sequence ${params.nextera_r1} --adapter_sequence_r2 ${params.nextera_r2}"
    }
    """
    fastp ${adapter} \
    --qualified_quality_phred ${params.qualtrim} \
    ${nextseq_trim} ${pico_opts} ${polyA_opts} \
    ${ntrim} \
    --length_required ${params.minlen} \
    -i ${reads[0]} -I ${reads[1]} -o ${prefix}_R1_trimmed.fastq.gz -O ${prefix}_R2_trimmed.fastq.gz \
    --detect_adapter_for_pe -j ${prefix}.fastp.json -h ${prefix}.fastp.html \
    --thread ${task.cpus} 2> ${prefix}_fasp.log
    """
  }
}

if(params.trimtool == "atropos"){
  trim_reads = trim_reads_atropos
  trim_reports = report_results_atropos
}else if (params.trimtool == "trimgalore"){
  trim_reads = trim_reads_trimgalore
  trim_reports = report_results_trimgalore
}else{
  trim_reads = trim_reads_fastp
  trim_reports = report_results_fastp
}

process trimReport {
  publishDir "${params.outdir}/trimReport", mode: 'copy',
              saveAs: {filename -> filename.indexOf(".log") > 0 ? "logs/$filename" : "$filename"}

  when:
  !params.skip_trimming

  input:
  set val(name), file(reads) from read_files_trimreport
  file trims from trim_reads
  file reports from trim_reports

  output:
  file '*_Basic_Metrics.trim.txt' into trim_report
  file "*_Adaptor_seq.trim.txt" into trim_adaptor

  script:
  prefix = reads[0].toString() - ~/(_1)?(_2)?(_R1)?(_R2)?(.R1)?(.R2)?(_val_1)?(_val_2)?(\.fq)?(\.fastq)?(\.gz)?$/
  if (params.singleEnd) {
       """
       trimming_report.py --tr1 ${reports} --r1 ${reads} --t1 ${trims} --u ${params.trimtool} --b ${name} --o ${prefix}
       """
  } else {

    if(params.trimtool == "trimgalore"){
       """
       trimming_report.py --tr1 ${reports[0]} --tr2 ${reports[1]} --r1 ${reads[0]} --r2 ${reads[1]} --t1 ${trims[0]} --t2 ${trims[1]} --u ${params.trimtool} --b ${name} --o ${prefix}
       """
    } else {
       """
       trimming_report.py --tr1 ${reports[0]} --r1 ${reads[0]} --r2 ${reads[1]} --t1 ${trims[0]} --t2 ${trims[1]} --u ${params.trimtool} --b ${name} --o ${prefix}
       """
    }
  }
}

/*
 * STEP 3 - FastQC after Trim!
*/
if(params.trimtool == "atropos"){
  fastqc_trim_reads = fastqc_atropos_reads
}else if (params.trimtool == "trimgalore"){
  fastqc_trim_reads = fastqc_trimgalore_reads
}else{
  fastqc_trim_reads = fastqc_fastp_reads
}
 
process fastqcTrimmed {
  tag "$name (trimmed reads)"
  publishDir "${params.outdir}/fastqc_trimmed", mode: 'copy',
      saveAs: {filename -> filename.indexOf(".zip") > 0 ? "zips/$filename" : "$filename"}

  when:
  !params.skip_fastqc_trim

  input:
  file reads from fastqc_trim_reads

  output:
  file "*_fastqc.{zip,html}" into fastqc_after_trim_results

  script:
  """
  fastqc -q $reads -t ${task.cpus}
  """
}

/*
 * MultiQC
 */

 process get_software_versions {
  output:
  file 'software_versions_mqc.yaml' into software_versions_yaml

  script:
  """
  echo $workflow.manifest.version &> v_rawqc.txt
  echo $workflow.nextflow.version &> v_nextflow.txt
  fastqc --version &> v_fastqc.txt
  trim_galore --version &> v_trimgalore.txt
  echo "lol" &> v_atropos.txt
  fastp --version &> v_fastp.txt
  multiqc --version &> v_multiqc.txt
  scrape_software_versions.py &> software_versions_mqc.yaml
  """
}

process workflow_summary_mqc {
  when:
  !params.skip_multiqc

  output:
  file 'workflow_summary_mqc.yaml' into workflow_summary_yaml

  exec:
  def yaml_file = task.workDir.resolve('workflow_summary_mqc.yaml')
  yaml_file.text  = """
  id: 'summary'
  description: " - this information is collected when the pipeline is started."
  section_name: 'Workflow Summary'
  section_href: 'https://gitlab.curie.fr/rawqc'
  plot_type: 'html'
  data: |
      <dl class=\"dl-horizontal\">
${summary.collect { k,v -> "            <dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }.join("\n")}
      </dl>
  """.stripIndent()
}

process multiqc {
  publishDir "${params.outdir}/MultiQC", mode: 'copy'

  input:
  file splan from ch_splan.collect()
  file metadata from ch_metadata.ifEmpty([])
  file multiqc_config from ch_multiqc_config
  file (fastqc:'fastqc/*') from fastqc_results.collect().ifEmpty([]) 
  file ('atropos/*') from trim_results_atropos.collect().ifEmpty([])
  file ('trimGalore/*') from trim_results_trimgalore.collect().ifEmpty([])
  file ('fastp/*') from trim_results_fastp.collect().ifEmpty([])
  file (fastqc:'fastqc_trimmed/*') from fastqc_after_trim_results.collect().ifEmpty([])
  file ('trimReport/*') from trim_report.collect().ifEmpty([])
  file ('trimReport/*') from trim_adaptor.collect().ifEmpty([])
  file ('software_versions/*') from software_versions_yaml.collect()
  file ('workflow_summary/*') from workflow_summary_yaml.collect()
  
  output:
  file splan
  file "*_report.html" into multiqc_report
  file "*_data"

  script:
  rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
  rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','') + "_multiqc_report" : ''
  isPE = params.singleEnd ? 0 : 1
  metadata_opts = params.metadata ? "--metadata ${metadata}" : ""

  """
  mqc_header.py --name "RNA-seq" --version ${workflow.manifest.version} ${metadata_opts} > multiqc-config-header.yaml
  stats2multiqc.sh ${splan} ${params.aligner} ${isPE}
  multiqc . -f $rtitle $rfilename -c $multiqc_config -c multiqc-config-header.yaml -m custom_content -m cutadapt -m fastqc -m fastp
  """
}
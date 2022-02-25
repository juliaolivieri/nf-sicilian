// Import generic module functions
include { initOptions; saveFiles; getSoftwareName } from './functions'

params.options = [:]
options        = initOptions(params.options)

process STAR_ALIGN {
    tag "${meta.id}"
    label 'process_high'
    publishDir "${params.outdir}",
        mode: params.publish_dir_mode,
        saveAs: { filename -> saveFiles(filename:filename, options:params.options, publish_dir:getSoftwareName(task.process), meta:meta, publish_by_meta:['id']) }

    // Note: 2.7X indices incompatible with AWS iGenomes.
    conda (params.enable_conda ? 'bioconda::star=2.7.5a' : null)
    if (workflow.containerEngine == 'singularity' && !params.singularity_pull_docker_container) {
        container 'https://depot.galaxyproject.org/singularity/star:2.7.5a--0'
    } else {
        container 'quay.io/biocontainers/star:2.7.5a--0'
    }

    input:
    tuple val(meta), path(reads)
    path  index
    path  gtf

    output:
    tuple val(meta), path('*d.out.bam')       , emit: bam
    tuple val(meta), path('*Log.final.out')   , emit: log_final
    tuple val(meta), path('*Log.out')         , emit: log_out
    tuple val(meta), path('*Log.progress.out'), emit: log_progress
    path  '*.version.txt'                          , emit: version
    tuple val(meta), path('*ReadsPerGene.out.tab')                  , emit: reads_per_gene
    tuple val(meta), path('*SJ.out.tab')                            , emit: sj_out_tab
    tuple val(meta), path('*Chimeric.out.junction')                 , emit: chimeric_out_junction

    tuple val(meta), path('*sortedByCoord.out.bam')  , optional:true, emit: bam_sorted
    tuple val(meta), path('*toTranscriptome.out.bam'), optional:true, emit: bam_transcript
    tuple val(meta), path('*Aligned.unsort.out.bam') , optional:true, emit: bam_unsorted
    tuple val(meta), path('*fastq.gz')               , optional:true, emit: fastq


    script:
    def software   = getSoftwareName(task.process)
    def prefix     = options.suffix ? "${meta.id}${options.suffix}" : "${meta.id}"
    def is_ss2     = params.smartseq2 ? true : false
    def ignore_gtf = params.star_ignore_sjdbgtf ? '' : "--sjdbGTFfile $gtf"
    def seq_center = params.seq_center ? "--outSAMattrRGline ID:$prefix 'CN:$params.seq_center' 'SM:$prefix'" : "--outSAMattrRGline ID:$prefix 'SM:$prefix'"
    def out_sam_type = (options.args.contains('--outSAMtype')) ? '' : '--outSAMtype BAM Unsorted'
    def mv_unsorted_bam = (options.args.contains('--outSAMtype BAM Unsorted SortedByCoordinate')) ? "mv ${prefix}.Aligned.out.bam ${prefix}.Aligned.unsort.out.bam" : ''
    def reads_v1 = "${reads[1]}"
    def reads_v2 = "${reads[1]}"
//    def reads_v2 = params.tenx ? "${reads[1]}" : "${reads}"
    if (params.tenx) {
        if (params.skip_umitools) {
            // Skipping umi tools, so providing already-extracted R2 reads. No R1 at all --> take the first one
            reads_v2 = "${reads[0]}"
        } else {
            // Did UMI tools, and only R2 has sequence to align since R1 is empty after UMI tools extract
            reads_v2 = "${reads[1]}"
        }
    } else {
        reads_v2 = "${reads}"
    }
    """
    STAR \\
        --genomeDir $index \\
        --readFilesIn $reads_v2  \\
        --runThreadN $task.cpus \\
        --outFileNamePrefix $prefix. \\
        $out_sam_type \\
        $ignore_gtf \\
        $seq_center \\
        $options.args

    if $is_ss2 ; then
        STAR \\
            --genomeDir $index \\
            --readFilesIn $reads_v1  \\
            --runThreadN $task.cpus \\
            --outFileNamePrefix ${prefix}.1 \\
            $out_sam_type \\
            $ignore_gtf \\
            $seq_center \\
            $options.args
    fi

    $mv_unsorted_bam

    if [ -f ${prefix}.Unmapped.out.mate1 ]; then
        mv ${prefix}.Unmapped.out.mate1 ${prefix}.unmapped_1.fastq
        gzip ${prefix}.unmapped_1.fastq
    fi
    if [ -f ${prefix}.Unmapped.out.mate2 ]; then
        mv ${prefix}.Unmapped.out.mate2 ${prefix}.unmapped_2.fastq
        gzip ${prefix}.unmapped_2.fastq
    fi

    STAR --version | sed -e "s/STAR_//g" > ${software}.version.txt
    """
}

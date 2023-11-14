
struct Runtime {
    String gatk_docker
    File? gatk_override
    Int max_retries
    Int preemptible
    Int cpu
    Int machine_mem
    Int command_mem
    Int disk
    Int boot_disk_size
}

workflow Mutect2 {
    input {
        # basic inputs
        File? intervals
        File ref_fasta
        File ref_fai
        File ref_dict
        File tumor_reads
        File tumor_reads_index
        File? normal_reads
        File? normal_reads_index
        File dbSNP_vcf
        File dbSNP_vcf_index
        Array[String] known_indels_sites_VCFs
        Array[String] known_indels_sites_indices

        # optional but usually recommended resources
        File? pon
        File? pon_idx
        File? gnomad
        File? gnomad_idx
        File? variants_for_contamination
        File? variants_for_contamination_idx

        # extra arguments
        String? m2_extra_args
        String? m2_extra_filtering_args
        String? getpileupsummaries_extra_args
        String? split_intervals_extra_args

        # additional modes and outputs
        File? realignment_index_bundle
        String? realignment_extra_args
        Boolean run_orientation_bias_mixture_model_filter = false
        Boolean make_bamout = false
        Boolean compress_vcfs = false
        File? gga_vcf
        File? gga_vcf_idx
        Boolean make_m3_training_dataset = false
        Boolean make_m3_test_dataset = false
        File? m3_training_dataset_truth_vcf
        File? m3_training_dataset_truth_vcf_idx


        # runtime
        String gatk_docker
        File? gatk_override
        String basic_bash_docker = "ubuntu:16.04"
        String python_docker = "python:2.7"
        Int scatter_count
        Int preemptible = 2
        Int max_retries = 1
        Int small_task_cpu = 2
        Int small_task_mem = 4
        Int small_task_disk = 100
        Int boot_disk_size = 12
        Int learn_read_orientation_mem = 8000
        Int filter_alignment_artifacts_mem = 9000
        String? gcs_project_for_requester_pays

        # Use as a last resort to increase the disk given to every task in case of ill behaving data
        Int emergency_extra_disk = 0
    }

    # Disk sizes used for dynamic sizing
    Int ref_size = ceil(size(ref_fasta, "GB") + size(ref_dict, "GB") + size(ref_fai, "GB"))
    Int tumor_reads_size = ceil(size(tumor_reads, "GB") + size(tumor_reads_index, "GB"))
    Int gnomad_vcf_size = if defined(gnomad) then ceil(size(gnomad, "GB")) else 0
    Int normal_reads_size = if defined(normal_reads) then ceil(size(normal_reads, "GB") + size(normal_reads_index, "GB")) else 0

    # This is added to every task as padding, should increase if systematically you need more disk for every call
    Int disk_pad = 10 + emergency_extra_disk

    Runtime standard_runtime = {"gatk_docker": gatk_docker, "gatk_override": gatk_override,
            "max_retries": max_retries, "preemptible": preemptible, "cpu": small_task_cpu,
            "machine_mem": small_task_mem * 1000, "command_mem": small_task_mem * 1000 - 500,
            "disk": small_task_disk + disk_pad, "boot_disk_size": boot_disk_size}

    Int tumor_reads_size = ceil(size(tumor_reads, "GB") + size(tumor_reads_index, "GB"))
    Int normal_reads_size = if defined(normal_reads) then ceil(size(normal_reads, "GB") + size(normal_reads_index, "GB")) else 0

    Int m2_output_size = tumor_reads_size / scatter_count
    #TODO: do we need to change this disk size now that NIO is always going to happen (for the google backend only)
    Int m2_per_scatter_size = (tumor_reads_size + normal_reads_size) + ref_size + gnomad_vcf_size + m2_output_size + disk_pad

     # Create list of sequences for scatter-gather parallelization 
    call CreateSequenceGroupingTSV {
        input:
        ref_dict = ref_dict,
        docker_image = python_docker,
        preemptible_tries = preemptible
    }
  
    # Perform Base Quality Score Recalibration (BQSR) on the sorted BAM in parallel
    scatter (subgroup in CreateSequenceGroupingTSV.sequence_grouping) {
    # Generate the recalibration model by interval
        call BaseRecalibrator {
            input:
                input_bam = tumor_reads,
                input_bam_index = tumor_reads_index,
                recalibration_report_filename =  "recal_data.csv",
                sequence_group_interval = subgroup,
                dbSNP_vcf = dbSNP_vcf,
                dbSNP_vcf_index = dbSNP_vcf_index,
                known_indels_sites_VCFs = known_indels_sites_VCFs,
                known_indels_sites_indices = known_indels_sites_indices,
                ref_dict = ref_dict,
                ref_fasta = ref_fasta,
                ref_fasta_index = ref_fai
                runtime_params = standard_runtime
        }
    } 
  
  # Merge the recalibration reports resulting from by-interval recalibration
    call GatherBqsrReports {
        input:
            input_bqsr_reports = BaseRecalibrator.recalibration_report,
            output_report_filename = base_file_name + ".recal_data.csv"
            runtime_params = standard_runtime
    }

    scatter (subgroup in CreateSequenceGroupingTSV.sequence_grouping_with_unmapped) {

        # Apply the recalibration model by interval
        call ApplyBQSR {
            input:
                input_bam = tumor_reads,
                input_bam_index = tumor_reads_index,
                output_bam_basename = "aligned.duplicates_marked.recalibrated",
                recalibration_report = GatherBqsrReports.output_bqsr_report,
                sequence_group_interval = subgroup,
                ref_dict = ref_dict,
                ref_fasta = ref_fasta,
                ref_fasta_index = ref_fai
                runtime_params = standard_runtime
        }
    } 

    # Merge the recalibrated BAM files resulting from by-interval recalibration
    call GatherBamFiles {
        input:
            input_bams = ApplyBQSR.recalibrated_bam,
            output_bam_basename = "GatherBam",
            compression_level = 2
            runtime_params = standard_runtime
    }
    
    call SplitIntervals {
        input:
            intervals = intervals,
            ref_fasta = ref_fasta,
            ref_fai = ref_fai,
            ref_dict = ref_dict,
            scatter_count = scatter_count,
            split_intervals_extra_args = split_intervals_extra_args,
            runtime_params = standard_runtime
    }

    scatter (subintervals in SplitIntervals.interval_files ) {
        call M2 {
            input:
                intervals = subintervals,
                ref_fasta = ref_fasta,
                ref_fai = ref_fai,
                ref_dict = ref_dict,
                tumor_reads = GatherBamFiles.output_bam,
                tumor_reads_index = GatherBamFiles.output_bam_index,
                normal_reads = normal_reads,
                normal_reads_index = normal_reads_index,
                pon = pon,
                pon_idx = pon_idx,
                gnomad = gnomad,
                gnomad_idx = gnomad_idx,
                preemptible = preemptible,
                max_retries = max_retries,
                m2_extra_args = m2_extra_args,
                getpileupsummaries_extra_args = getpileupsummaries_extra_args,
                variants_for_contamination = variants_for_contamination,
                variants_for_contamination_idx = variants_for_contamination_idx,
                make_bamout = make_bamout,
                run_ob_filter = run_orientation_bias_mixture_model_filter,
                compress_vcfs = compress_vcfs,
                gga_vcf = gga_vcf,
                gga_vcf_idx = gga_vcf_idx,
                make_m3_training_dataset = make_m3_training_dataset,
                make_m3_test_dataset = make_m3_test_dataset,
                m3_training_dataset_truth_vcf = m3_training_dataset_truth_vcf,
                m3_training_dataset_truth_vcf_idx = m3_training_dataset_truth_vcf_idx,
                gatk_override = gatk_override,
                gatk_docker = gatk_docker,
                disk_space = m2_per_scatter_size,
                gcs_project_for_requester_pays = gcs_project_for_requester_pays
        }
    }

    Int merged_vcf_size = ceil(size(M2.unfiltered_vcf, "GB"))
    Int merged_bamout_size = ceil(size(M2.output_bamOut, "GB"))

    if (run_orientation_bias_mixture_model_filter) {
        call LearnReadOrientationModel {
            input:
                f1r2_tar_gz = M2.f1r2_counts,
                runtime_params = standard_runtime,
                mem = learn_read_orientation_mem
        }
    }

    call MergeVCFs {
        input:
            input_vcfs = M2.unfiltered_vcf,
            input_vcf_indices = M2.unfiltered_vcf_idx,
            compress_vcfs = compress_vcfs,
            runtime_params = standard_runtime
    }

    if (make_bamout) {
        call MergeBamOuts {
            input:
                ref_fasta = ref_fasta,
                ref_fai = ref_fai,
                ref_dict = ref_dict,
                bam_outs = M2.output_bamOut,
                runtime_params = standard_runtime,
                disk_space = ceil(merged_bamout_size * 4) + disk_pad,
        }
    }

    call MergeStats { input: stats = M2.stats, runtime_params = standard_runtime }

    if (defined(variants_for_contamination)) {
        call MergePileupSummaries as MergeTumorPileups {
            input:
                input_tables = flatten(M2.tumor_pileups),
                output_name = "tumor-pileups",
                ref_dict = ref_dict,
                runtime_params = standard_runtime
        }

        if (defined(normal_reads)){
            call MergePileupSummaries as MergeNormalPileups {
                input:
                    input_tables = flatten(M2.normal_pileups),
                    output_name = "normal-pileups",
                    ref_dict = ref_dict,
                    runtime_params = standard_runtime
            }
        }

        call CalculateContamination {
            input:
                tumor_pileups = MergeTumorPileups.merged_table,
                normal_pileups = MergeNormalPileups.merged_table,
                runtime_params = standard_runtime
        }
    }

    if (make_m3_training_dataset || make_m3_test_dataset) {
        call Concatenate {
            input:
                input_files = M2.m3_dataset,
                gatk_docker = gatk_docker
        }
    }

    call Filter {
        input:
            ref_fasta = ref_fasta,
            ref_fai = ref_fai,
            ref_dict = ref_dict,
            intervals = intervals,
            unfiltered_vcf = MergeVCFs.merged_vcf,
            unfiltered_vcf_idx = MergeVCFs.merged_vcf_idx,
            compress_vcfs = compress_vcfs,
            mutect_stats = MergeStats.merged_stats,
            contamination_table = CalculateContamination.contamination_table,
            maf_segments = CalculateContamination.maf_segments,
            artifact_priors_tar_gz = LearnReadOrientationModel.artifact_prior_table,
            m2_extra_filtering_args = m2_extra_filtering_args,
            runtime_params = standard_runtime,
            disk_space = ceil(size(MergeVCFs.merged_vcf, "GB") * 4) + disk_pad
    }

    if (defined(realignment_index_bundle)) {
        call FilterAlignmentArtifacts {
            input:
                ref_fasta = ref_fasta,
                ref_fai = ref_fai,
                ref_dict = ref_dict,
                reads = GatherBamFiles.output_bam,
                reads_index = GatherBamFiles.output_bam_index,
                realignment_index_bundle = select_first([realignment_index_bundle]),
                realignment_extra_args = realignment_extra_args,
                compress_vcfs = compress_vcfs,
                input_vcf = Filter.filtered_vcf,
                input_vcf_idx = Filter.filtered_vcf_idx,
                runtime_params = standard_runtime,
                mem = filter_alignment_artifacts_mem,
                gcs_project_for_requester_pays = gcs_project_for_requester_pays
        }
    }

    output {
        File filtered_vcf = select_first([FilterAlignmentArtifacts.filtered_vcf, Filter.filtered_vcf])
        File filtered_vcf_idx = select_first([FilterAlignmentArtifacts.filtered_vcf_idx, Filter.filtered_vcf_idx])
        File filtering_stats = Filter.filtering_stats
        File mutect_stats = MergeStats.merged_stats
        File bqsr_report = GatherBqsrReports.output_bqsr_report
        File? contamination_table = CalculateContamination.contamination_table

        File? bamout = MergeBamOuts.merged_bam_out
        File? bamout_index = MergeBamOuts.merged_bam_out_index
        File? maf_segments = CalculateContamination.maf_segments
        File? read_orientation_model_params = LearnReadOrientationModel.artifact_prior_table
        File? m3_dataset = Concatenate.concatenated
    }
}

task CreateSequenceGroupingTSV {
    input {
        File ref_dict  
  
        Int preemptible_tries
        Float mem_size_gb = 2

        String docker_image
    }
    # Use python to create the Sequencing Groupings used for BQSR and PrintReads Scatter. 
    # It outputs to stdout where it is parsed into a wdl Array[Array[String]]
    # e.g. [["1"], ["2"], ["3", "4"], ["5"], ["6", "7", "8"]]
    command <<<
        python <<CODE
        with open("~{ref_dict}", "r") as ref_dict_file:
            sequence_tuple_list = []
            longest_sequence = 0
            for line in ref_dict_file:
                if line.startswith("@SQ"):
                    line_split = line.split("	")
                    # (Sequence_Name, Sequence_Length)
                    sequence_tuple_list.append((line_split[1].split("SN:")[1], int(line_split[2].split("LN:")[1])))
            longest_sequence = sorted(sequence_tuple_list, key=lambda x: x[1], reverse=True)[0][1]
        # We are adding this to the intervals because hg38 has contigs named with embedded colons (:) and a bug in 
        # some versions of GATK strips off the last element after a colon, so we add this as a sacrificial element.
        hg38_protection_tag = ":1+"
        # initialize the tsv string with the first sequence
        tsv_string = sequence_tuple_list[0][0] + hg38_protection_tag
        temp_size = sequence_tuple_list[0][1]
        for sequence_tuple in sequence_tuple_list[1:]:
            if temp_size + sequence_tuple[1] <= longest_sequence:
                temp_size += sequence_tuple[1]
                tsv_string += "	" + sequence_tuple[0] + hg38_protection_tag
            else:
                tsv_string += "
" + sequence_tuple[0] + hg38_protection_tag
                temp_size = sequence_tuple[1]
        # add the unmapped sequences as a separate line to ensure that they are recalibrated as well
        with open("sequence_grouping.txt","w") as tsv_file:
            tsv_file.write(tsv_string)
            tsv_file.close()

        tsv_string += '
' + "unmapped"

        with open("sequence_grouping_with_unmapped.txt","w") as tsv_file_with_unmapped:
            tsv_file_with_unmapped.write(tsv_string)
            tsv_file_with_unmapped.close()
        CODE
    >>>
    runtime {
        docker: runtime_params.gatk_docker
        bootDiskSizeGb: runtime_params.boot_disk_size
        memory: runtime_params.machine_mem + " MB"
        disks: "local-disk " + runtime_params.disk + " HDD"
        preemptible: runtime_params.preemptible
        maxRetries: runtime_params.max_retries
        cpu: runtime_params.cpu
    }
    output {
        Array[Array[String]] sequence_grouping = read_tsv("sequence_grouping.txt")
        Array[Array[String]] sequence_grouping_with_unmapped = read_tsv("sequence_grouping_with_unmapped.txt")
    }
}

# Generate Base Quality Score Recalibration (BQSR) model
task BaseRecalibrator {
    input {
        File input_bam
        File input_bam_index
        String recalibration_report_filename
        Array[String] sequence_group_interval
        File dbSNP_vcf
        File dbSNP_vcf_index
        Array[String] known_indels_sites_VCFs
        Array[String] known_indels_sites_indices
        File ref_dict
        File ref_fasta
        File ref_fasta_index
  
        Runtime runtime_params
    }

    command {
        set -e
        export GATK_LOCAL_JAR=~{default="/root/gatk.jar" runtime_params.gatk_override}
        gatk --java-options "-Xms~{runtime_params.command_mem}m" BaseRecalibrator             -R ~{ref_fasta}             -I ~{input_bam}             -L ~{sequence_group_interval}             --use-original-qualities             -O ~{recalibration_report_filename}             --known-sites ~{dbSNP_vcf}             --known-sites ~{sep=' --known-sites ' known_indels_sites_VCFs}
    }
    runtime {
        docker: runtime_params.gatk_docker
        bootDiskSizeGb: runtime_params.boot_disk_size
        memory: runtime_params.machine_mem + " MB"
        disks: "local-disk " + runtime_params.disk + " HDD"
        preemptible: runtime_params.preemptible
        maxRetries: runtime_params.max_retries
        cpu: runtime_params.cpu
    }
    output {
        File recalibration_report = "~{recalibration_report_filename}"
    }
}

# Combine multiple recalibration tables from scattered BaseRecalibrator runs
# Note that when run from GATK 3.x the tool is not a walker and is invoked differently.
task GatherBqsrReports {
    input { 
        Array[File] input_bqsr_reports
        String output_report_filename

        Runtime runtime_params
    }

    command {
        set -e
        export GATK_LOCAL_JAR=~{default="/root/gatk.jar" runtime_params.gatk_override}
        gatk --java-options "-Xms~{runtime_params.command_mem}m"             GatherBQSRReports             -I ~{sep=' -I ' input_bqsr_reports}             -O ~{output_report_filename}
    }
    runtime {
        docker: runtime_params.gatk_docker
        bootDiskSizeGb: runtime_params.boot_disk_size
        memory: runtime_params.machine_mem + " MB"
        disks: "local-disk " + runtime_params.disk + " HDD"
        preemptible: runtime_params.preemptible
        maxRetries: runtime_params.max_retries
        cpu: runtime_params.cpu
    }
    output {
        File output_bqsr_report = "~{output_report_filename}"
    }
}

# Apply Base Quality Score Recalibration (BQSR) model
task ApplyBQSR {
    input {
        File input_bam
        File input_bam_index
        String output_bam_basename
        File recalibration_report
        Array[String] sequence_group_interval
        File ref_dict
        File ref_fasta
        File ref_fasta_index

        Runtime runtime_params
    }

    command {
        set -e
        export GATK_LOCAL_JAR=~{default="/root/gatk.jar" runtime_params.gatk_override}
        gatk --java-options "-Xms~{runtime_params.command_mem}m"             ApplyBQSR             -R ~{ref_fasta}             -I ~{input_bam}             -O ~{output_bam_basename}.bam             -L ~{sep=" -L " sequence_group_interval}             -bqsr ~{recalibration_report}             --static-quantized-quals 10 --static-quantized-quals 20 --static-quantized-quals 30             --add-output-sam-program-record             --create-output-bam-md5             --use-original-qualities
    }
    runtime {
        docker: runtime_params.gatk_docker
        bootDiskSizeGb: runtime_params.boot_disk_size
        memory: runtime_params.machine_mem + " MB"
        disks: "local-disk " + runtime_params.disk + " HDD"
        preemptible: runtime_params.preemptible
        maxRetries: runtime_params.max_retries
        cpu: runtime_params.cpu
    }
    output {
        File recalibrated_bam = "~{output_bam_basename}.bam"
    }
}

# Combine multiple recalibrated BAM files from scattered ApplyRecalibration runs
task GatherBamFiles {
    input {
        Array[File] input_bams
        String output_bam_basename

        Int compression_level
        Runtime runtime_params
    }

    command {
        set -e
        export GATK_LOCAL_JAR=~{default="/root/gatk.jar" runtime_params.gatk_override}
        gatk --java-options "-Dsamjdk.compression_level=~{compression_level} -Xms~{runtime_params.command_mem}m"             GatherBamFiles             --INPUT ~{sep=' --INPUT ' input_bams}             --OUTPUT ~{output_bam_basename}.bam             --CREATE_INDEX true             --CREATE_MD5_FILE true
    }
    runtime {
        docker: runtime_params.gatk_docker
        bootDiskSizeGb: runtime_params.boot_disk_size
        memory: runtime_params.machine_mem + " MB"
        disks: "local-disk " + runtime_params.disk + " HDD"
        preemptible: runtime_params.preemptible
        maxRetries: runtime_params.max_retries
        cpu: runtime_params.cpu
    }
    output {
        File output_bam = "~{output_bam_basename}.bam"
        File output_bam_index = "~{output_bam_basename}.bai"
        File output_bam_md5 = "~{output_bam_basename}.bam.md5"
    }
}

task SplitIntervals {
    input {
      File? intervals
      File ref_fasta
      File ref_fai
      File ref_dict
      Int scatter_count
      String? split_intervals_extra_args

      # runtime
      Runtime runtime_params
    }

    command {
        set -e
        export GATK_LOCAL_JAR=~{default="/root/gatk.jar" runtime_params.gatk_override}

        mkdir interval-files
        gatk --java-options "-Xmx~{runtime_params.command_mem}m" SplitIntervals             -R ~{ref_fasta}             ~{"-L " + intervals}             -scatter ~{scatter_count}             -O interval-files             ~{split_intervals_extra_args}
        cp interval-files/*.interval_list .
    }

    runtime {
        docker: runtime_params.gatk_docker
        bootDiskSizeGb: runtime_params.boot_disk_size
        memory: runtime_params.machine_mem + " MB"
        disks: "local-disk " + runtime_params.disk + " HDD"
        preemptible: runtime_params.preemptible
        maxRetries: runtime_params.max_retries
        cpu: runtime_params.cpu
    }

    output {
        Array[File] interval_files = glob("*.interval_list")
    }
}

task M2 {
    input {
        File? intervals
        File ref_fasta
        File ref_fai
        File ref_dict
        File tumor_reads
        File tumor_reads_index
        File? normal_reads
        File? normal_reads_index
        File? pon
        File? pon_idx
        File? gnomad
        File? gnomad_idx
        String? m2_extra_args
        String? getpileupsummaries_extra_args
        Boolean? make_bamout
        Boolean? run_ob_filter
        Boolean compress_vcfs
        File? gga_vcf
        File? gga_vcf_idx
        File? variants_for_contamination
        File? variants_for_contamination_idx

        File? gatk_override

        String? gcs_project_for_requester_pays

        Boolean make_m3_training_dataset = false
        Boolean make_m3_test_dataset = false
        File? m3_training_dataset_truth_vcf
        File? m3_training_dataset_truth_vcf_idx

        # runtime
        String gatk_docker
        Int? mem
        Int? preemptible
        Int? max_retries
        Int? disk_space
        Int? cpu
        Boolean use_ssd = false
    }

    String output_vcf = "output" + if compress_vcfs then ".vcf.gz" else ".vcf"
    String output_vcf_idx = output_vcf + if compress_vcfs then ".tbi" else ".idx"

    String output_stats = output_vcf + ".stats"

    # Mem is in units of GB but our command and memory runtime values are in MB
    Int machine_mem = if defined(mem) then mem * 1000 else 3500
    Int command_mem = machine_mem - 500

    parameter_meta{
        intervals: {localization_optional: true}
        ref_fasta: {localization_optional: true}
        ref_fai: {localization_optional: true}
        ref_dict: {localization_optional: true}
        tumor_reads: {localization_optional: true}
        tumor_reads_index: {localization_optional: true}
        normal_reads: {localization_optional: true}
        normal_reads_index: {localization_optional: true}
        pon: {localization_optional: true}
        pon_idx: {localization_optional: true}
        gnomad: {localization_optional: true}
        gnomad_idx: {localization_optional: true}
        gga_vcf: {localization_optional: true}
        gga_vcf_idx: {localization_optional: true}
        variants_for_contamination: {localization_optional: true}
        variants_for_contamination_idx: {localization_optional: true}
        m3_training_dataset_truth_vcf: {localization_optional: true}
        m3_training_dataset_truth_vcf_idx: {localization_optional: true}
    }

    command <<<
        set -e

        export GATK_LOCAL_JAR=~{default="/root/gatk.jar" gatk_override}

        # We need to create these files regardless, even if they stay empty
        touch bamout.bam
        touch f1r2.tar.gz
        touch dataset.txt
        echo "" > normal_name.txt

        gatk --java-options "-Xmx~{command_mem}m" GetSampleName -R ~{ref_fasta} -I ~{tumor_reads} -O tumor_name.txt -encode         ~{"--gcs-project-for-requester-pays " + gcs_project_for_requester_pays}
        tumor_command_line="-I ~{tumor_reads} -tumor `cat tumor_name.txt`"

        if [[ ! -z "~{normal_reads}" ]]; then
            gatk --java-options "-Xmx~{command_mem}m" GetSampleName -R ~{ref_fasta} -I ~{normal_reads} -O normal_name.txt -encode             ~{"--gcs-project-for-requester-pays " + gcs_project_for_requester_pays}
            normal_command_line="-I ~{normal_reads} -normal `cat normal_name.txt`"
        fi

        gatk --java-options "-Xmx~{command_mem}m" Mutect2             -R ~{ref_fasta}             $tumor_command_line             $normal_command_line             ~{"--germline-resource " + gnomad}             ~{"-pon " + pon}             ~{"-L " + intervals}             ~{"--alleles " + gga_vcf}             -O "~{output_vcf}"             ~{true='--bam-output bamout.bam' false='' make_bamout}             ~{true='--f1r2-tar-gz f1r2.tar.gz' false='' run_ob_filter}             ~{true='--mutect3-dataset dataset.txt' false='' make_m3_test_dataset}             ~{true='--mutect3-dataset dataset.txt --mutect3-training-mode' false='' make_m3_training_dataset}             ~{"--mutect3-training-truth " + m3_training_dataset_truth_vcf}             ~{m2_extra_args}             ~{"--gcs-project-for-requester-pays " + gcs_project_for_requester_pays}

        m2_exit_code=$?

        ### GetPileupSummaries

        # If the variants for contamination and the intervals for this scatter don't intersect, GetPileupSummaries
        # throws an error.  However, there is nothing wrong with an empty intersection for our purposes; it simply doesn't
        # contribute to the merged pileup summaries that we create downstream.  We implement this by with array outputs.
        # If the tool errors, no table is created and the glob yields an empty array.
        set +e

        if [[ ! -z "~{variants_for_contamination}" ]]; then
            gatk --java-options "-Xmx~{command_mem}m" GetPileupSummaries -R ~{ref_fasta} -I ~{tumor_reads} ~{"--interval-set-rule INTERSECTION -L " + intervals}                 -V ~{variants_for_contamination} -L ~{variants_for_contamination} -O tumor-pileups.table ~{getpileupsummaries_extra_args}                 ~{"--gcs-project-for-requester-pays " + gcs_project_for_requester_pays}


            if [[ ! -z "~{normal_reads}" ]]; then
                gatk --java-options "-Xmx~{command_mem}m" GetPileupSummaries -R ~{ref_fasta} -I ~{normal_reads} ~{"--interval-set-rule INTERSECTION -L " + intervals}                     -V ~{variants_for_contamination} -L ~{variants_for_contamination} -O normal-pileups.table ~{getpileupsummaries_extra_args}                     ~{"--gcs-project-for-requester-pays " + gcs_project_for_requester_pays}
            fi
        fi

        # the script only fails if Mutect2 itself fails
        exit $m2_exit_code
    >>>

    runtime {
        docker: gatk_docker
        bootDiskSizeGb: 12
        memory: machine_mem + " MB"
        disks: "local-disk " + select_first([disk_space, 100]) + if use_ssd then " SSD" else " HDD"
        preemptible: select_first([preemptible, 10])
        maxRetries: select_first([max_retries, 0])
        cpu: select_first([cpu, 1])
    }

    output {
        File unfiltered_vcf = "~{output_vcf}"
        File unfiltered_vcf_idx = "~{output_vcf_idx}"
        File output_bamOut = "bamout.bam"
        String tumor_sample = read_string("tumor_name.txt")
        String normal_sample = read_string("normal_name.txt")
        File stats = "~{output_stats}"
        File f1r2_counts = "f1r2.tar.gz"
        Array[File] tumor_pileups = glob("*tumor-pileups.table")
        Array[File] normal_pileups = glob("*normal-pileups.table")
        File m3_dataset = "dataset.txt"
    }
}

task MergeVCFs {
    input {
      Array[File] input_vcfs
      Array[File] input_vcf_indices
      Boolean compress_vcfs
      Runtime runtime_params
    }

    String output_vcf = if compress_vcfs then "merged.vcf.gz" else "merged.vcf"
    String output_vcf_idx = output_vcf + if compress_vcfs then ".tbi" else ".idx"

    # using MergeVcfs instead of GatherVcfs so we can create indices
    # WARNING 2015-10-28 15:01:48 GatherVcfs  Index creation not currently supported when gathering block compressed VCFs.
    command {
        set -e
        export GATK_LOCAL_JAR=~{default="/root/gatk.jar" runtime_params.gatk_override}
        gatk --java-options "-Xmx~{runtime_params.command_mem}m" MergeVcfs -I ~{sep=' -I ' input_vcfs} -O ~{output_vcf}
    }

    runtime {
        docker: runtime_params.gatk_docker
        bootDiskSizeGb: runtime_params.boot_disk_size
        memory: runtime_params.machine_mem + " MB"
        disks: "local-disk " + runtime_params.disk + " HDD"
        preemptible: runtime_params.preemptible
        maxRetries: runtime_params.max_retries
        cpu: runtime_params.cpu
    }

    output {
        File merged_vcf = "~{output_vcf}"
        File merged_vcf_idx = "~{output_vcf_idx}"
    }
}

task MergeBamOuts {
    input {
      File ref_fasta
      File ref_fai
      File ref_dict
      Array[File]+ bam_outs
      Runtime runtime_params
      Int? disk_space   #override to request more disk than default small task params
    }

    command <<<
        # This command block assumes that there is at least one file in bam_outs.
        #  Do not call this task if len(bam_outs) == 0
        set -e
        export GATK_LOCAL_JAR=~{default="/root/gatk.jar" runtime_params.gatk_override}
        gatk --java-options "-Xmx~{runtime_params.command_mem}m" GatherBamFiles             -I ~{sep=" -I " bam_outs} -O unsorted.out.bam -R ~{ref_fasta}

        # We must sort because adjacent scatters may have overlapping (padded) assembly regions, hence
        # overlapping bamouts

        gatk --java-options "-Xmx~{runtime_params.command_mem}m" SortSam -I unsorted.out.bam             -O bamout.bam --SORT_ORDER coordinate -VALIDATION_STRINGENCY LENIENT
        gatk --java-options "-Xmx~{runtime_params.command_mem}m" BuildBamIndex -I bamout.bam -VALIDATION_STRINGENCY LENIENT
    >>>

    runtime {
        docker: runtime_params.gatk_docker
        bootDiskSizeGb: runtime_params.boot_disk_size
        memory: runtime_params.machine_mem + " MB"
        disks: "local-disk " + select_first([disk_space, runtime_params.disk]) + " HDD"
        preemptible: runtime_params.preemptible
        maxRetries: runtime_params.max_retries
        cpu: runtime_params.cpu
    }

    output {
        File merged_bam_out = "bamout.bam"
        File merged_bam_out_index = "bamout.bai"
    }
}


task MergeStats {
    input {
      Array[File]+ stats
      Runtime runtime_params
    }

    command {
        set -e
        export GATK_LOCAL_JAR=~{default="/root/gatk.jar" runtime_params.gatk_override}


        gatk --java-options "-Xmx~{runtime_params.command_mem}m" MergeMutectStats             -stats ~{sep=" -stats " stats} -O merged.stats
    }

    runtime {
        docker: runtime_params.gatk_docker
        bootDiskSizeGb: runtime_params.boot_disk_size
        memory: runtime_params.machine_mem + " MB"
        disks: "local-disk " + runtime_params.disk + " HDD"
        preemptible: runtime_params.preemptible
        maxRetries: runtime_params.max_retries
        cpu: runtime_params.cpu
    }

    output {
        File merged_stats = "merged.stats"
    }
}

task MergePileupSummaries {
    input {
      Array[File] input_tables
      String output_name
      File ref_dict
      Runtime runtime_params
    }

    command {
        set -e
        export GATK_LOCAL_JAR=~{default="/root/gatk.jar" runtime_params.gatk_override}

        gatk --java-options "-Xmx~{runtime_params.command_mem}m" GatherPileupSummaries         --sequence-dictionary ~{ref_dict}         -I ~{sep=' -I ' input_tables}         -O ~{output_name}.tsv
    }

    runtime {
        docker: runtime_params.gatk_docker
        bootDiskSizeGb: runtime_params.boot_disk_size
        memory: runtime_params.machine_mem + " MB"
        disks: "local-disk " + runtime_params.disk + " HDD"
        preemptible: runtime_params.preemptible
        maxRetries: runtime_params.max_retries
        cpu: runtime_params.cpu
    }

    output {
        File merged_table = "~{output_name}.tsv"
    }
}

# Learning step of the orientation bias mixture model, which is the recommended orientation bias filter as of September 2018
task LearnReadOrientationModel {
    input {
      Array[File] f1r2_tar_gz
      Runtime runtime_params
      Int? mem  #override memory
    }

    Int machine_mem = select_first([mem, runtime_params.machine_mem])
    Int command_mem = machine_mem - 1000

    command {
        set -e
        export GATK_LOCAL_JAR=~{default="/root/gatk.jar" runtime_params.gatk_override}

        gatk --java-options "-Xmx~{command_mem}m" LearnReadOrientationModel             -I ~{sep=" -I " f1r2_tar_gz}             -O "artifact-priors.tar.gz"
    }

    runtime {
        docker: runtime_params.gatk_docker
        bootDiskSizeGb: runtime_params.boot_disk_size
        memory: machine_mem + " MB"
        disks: "local-disk " + runtime_params.disk + " HDD"
        preemptible: runtime_params.preemptible
        maxRetries: runtime_params.max_retries
        cpu: runtime_params.cpu
    }

    output {
        File artifact_prior_table = "artifact-priors.tar.gz"
    }

}

task CalculateContamination {
    input {
      String? intervals
      File tumor_pileups
      File? normal_pileups
      Runtime runtime_params
    }

    command {
        set -e

        export GATK_LOCAL_JAR=~{default="/root/gatk.jar" runtime_params.gatk_override}

        gatk --java-options "-Xmx~{runtime_params.command_mem}m" CalculateContamination -I ~{tumor_pileups}         -O contamination.table --tumor-segmentation segments.table ~{"-matched " + normal_pileups}
    }

    runtime {
        docker: runtime_params.gatk_docker
        bootDiskSizeGb: runtime_params.boot_disk_size
        memory: runtime_params.machine_mem + " MB"
        disks: "local-disk " + runtime_params.disk + " HDD"
        preemptible: runtime_params.preemptible
        maxRetries: runtime_params.max_retries
        cpu: runtime_params.cpu
    }

    output {
        File contamination_table = "contamination.table"
        File maf_segments = "segments.table"
    }
}

task Filter {
    input {
        File? intervals
        File ref_fasta
        File ref_fai
        File ref_dict
        File unfiltered_vcf
        File unfiltered_vcf_idx
        Boolean compress_vcfs
        File? mutect_stats
        File? artifact_priors_tar_gz
        File? contamination_table
        File? maf_segments
        String? m2_extra_filtering_args

        Runtime runtime_params
        Int? disk_space
    }

    String output_vcf = if compress_vcfs then "filtered.vcf.gz" else "filtered.vcf"
    String output_vcf_idx = output_vcf + if compress_vcfs then ".tbi" else ".idx"

    parameter_meta{
      ref_fasta: {localization_optional: true}
      ref_fai: {localization_optional: true}
      ref_dict: {localization_optional: true}
    }

    command {
        set -e

        export GATK_LOCAL_JAR=~{default="/root/gatk.jar" runtime_params.gatk_override}

        gatk --java-options "-Xmx~{runtime_params.command_mem}m" FilterMutectCalls -V ~{unfiltered_vcf}             -R ~{ref_fasta}             -O ~{output_vcf}             ~{"--contamination-table " + contamination_table}             ~{"--tumor-segmentation " + maf_segments}             ~{"--ob-priors " + artifact_priors_tar_gz}             ~{"-stats " + mutect_stats}             --filtering-stats filtering.stats             ~{m2_extra_filtering_args}
    }

    runtime {
        docker: runtime_params.gatk_docker
        bootDiskSizeGb: runtime_params.boot_disk_size
        memory: runtime_params.machine_mem + " MB"
        disks: "local-disk " + select_first([disk_space, runtime_params.disk]) + " HDD"
        preemptible: runtime_params.preemptible
        maxRetries: runtime_params.max_retries
        cpu: runtime_params.cpu
    }

    output {
        File filtered_vcf = "~{output_vcf}"
        File filtered_vcf_idx = "~{output_vcf_idx}"
        File filtering_stats = "filtering.stats"
    }
}

task FilterAlignmentArtifacts {
    input {
      File ref_fasta
      File ref_fai
      File ref_dict
      File input_vcf
      File input_vcf_idx
      File reads
      File reads_index
      Boolean compress_vcfs
      File realignment_index_bundle
      String? realignment_extra_args
      String? gcs_project_for_requester_pays
      Runtime runtime_params
      Int mem
    }

    String output_vcf = if compress_vcfs then "filtered.vcf.gz" else "filtered.vcf"
    String output_vcf_idx = output_vcf +  if compress_vcfs then ".tbi" else ".idx"

    Int machine_mem = mem
    Int command_mem = machine_mem - 500

    parameter_meta{
      ref_fasta: {localization_optional: true}
      ref_fai: {localization_optional: true}
      ref_dict: {localization_optional: true}
      input_vcf: {localization_optional: true}
      input_vcf_idx: {localization_optional: true}
      reads: {localization_optional: true}
      reads_index: {localization_optional: true}
    }

    command {
        set -e

        export GATK_LOCAL_JAR=~{default="/root/gatk.jar" runtime_params.gatk_override}

        gatk --java-options "-Xmx~{command_mem}m" FilterAlignmentArtifacts             -R ~{ref_fasta}             -V ~{input_vcf}             -I ~{reads}             --bwa-mem-index-image ~{realignment_index_bundle}             ~{realignment_extra_args}             -O ~{output_vcf}             ~{"--gcs-project-for-requester-pays " + gcs_project_for_requester_pays}
    }

    runtime {
        docker: runtime_params.gatk_docker
        bootDiskSizeGb: runtime_params.boot_disk_size
        memory: machine_mem + " MB"
        disks: "local-disk " + runtime_params.disk + " HDD"
        preemptible: runtime_params.preemptible
        maxRetries: runtime_params.max_retries
        cpu: runtime_params.cpu
    }

    output {
        File filtered_vcf = "~{output_vcf}"
        File filtered_vcf_idx = "~{output_vcf_idx}"
    }
}

task Concatenate {
    input {
        Array[File] input_files
        Int? mem
        String gatk_docker
    }

    Int machine_mem = if defined(mem) then mem * 1000 else 7000

    command {
        cat ~{sep=' ' input_files} > output.txt
    }

    runtime {
        docker: gatk_docker
        bootDiskSizeGb: 12
        memory: machine_mem + " MB"
        disks: "local-disk 100 HDD"
        preemptible: 1
        maxRetries: 1
        cpu: 2
    }

    output {
        File concatenated = "output.txt"
    }
}


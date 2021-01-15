#!/usr/bin/env nextflow

genome_file = file(params.genome_file)

OUTDIR = params.outdir+'/'+params.subdir
CRONDIR = params.crondir

csv = file(params.csv)
mode = csv.countLines() > 2 ? "paired" : "unpaired"
println(csv)
println(mode)


workflow.onComplete {

	def msg = """\
		Pipeline execution summary
		---------------------------
		Completed at: ${workflow.complete}
		Duration    : ${workflow.duration}
		Success     : ${workflow.success}
		scriptFile  : ${workflow.scriptFile}
		workDir     : ${workflow.workDir}
		exit status : ${workflow.exitStatus}
		errorMessage: ${workflow.errorMessage}
		errorReport :
		"""
		.stripIndent()
	def error = """\
		${workflow.errorReport}
		"""
		.stripIndent()

	base = csv.getBaseName()
	logFile = file("/fs1/results/cron/logs/" + base + ".complete")
	logFile.text = msg
	logFile.append(error)
}

// Print commit-version of active deployment
file(params.git)
    .readLines()
    .each { println "git commit-hash: "+it }
// Print active container
container = file(params.container).toRealPath()
println("container: "+container)

Channel
    .fromPath(params.csv).splitCsv(header:true)
    .map{ row-> tuple(row.group, row.id, row.type, file(row.read1), file(row.read2)) }
    .into { fastq_umi; fastq_noumi }

Channel
    .fromPath(params.csv).splitCsv(header:true)
    .map{ row-> tuple(row.group, row.id, row.type, (row.containsKey("ffpe") ? row.ffpe : false)) }
    .into { meta_aggregate; meta_germline; meta_pon; meta_cnvkit; meta_melt; meta_cnvplot }

Channel
    .fromPath(params.csv).splitCsv(header:true)
    .map{ row-> tuple(row.group, row.type, row.clarity_sample_id, row.clarity_pool_id) }
    .set { meta_coyote }

Channel
    .fromPath(params.csv).splitCsv(header:true)
    .map{ row-> tuple(row.id, row.read1, row.read2) }
    .set{ meta_qc }

Channel
    .fromPath(params.csv).splitCsv(header:true)
    .map{ row-> tuple(row.group, row.id, row.type, row.clarity_sample_id, row.clarity_pool_id) }
    .set { meta_const }



// Split bed file in to smaller parts to be used for parallel variant calling
Channel
    .fromPath("${params.regions_bed}")
    .ifEmpty { exit 1, "Regions bed file not found: ${params.regions_bed}" }
    .splitText( by: 200, file: 'bedpart.bed' )
    .into { beds_mutect; beds_freebayes; beds_tnscope; beds_vardict }



process bwa_umi {
	publishDir "${OUTDIR}/bam", mode: 'copy', overwrite: true
	cpus params.cpu_all
	memory '128 GB'
	time '2h'
	errorStrategy 'retry'
	maxErrors 5
	tag "$id"
	scratch true
	stageInMode 'copy'
	stageOutMode 'copy'

	input:
		set group, id, type, file(r1), file(r2) from fastq_umi

	output:
		set group, id, type, file("${id}.${type}.bwa.umi.sort.bam"), file("${id}.${type}.bwa.umi.sort.bam.bai") into bam_umi_bqsr, bam_umi_confirm
		set group, id, type, file("${id}.${type}.bwa.sort.bam"), file("${id}.${type}.bwa.sort.bam.bai") into bam_umi_markdup

	when:
		params.umi

	"""

	export skip_coord_end=true
	
	sentieon umi extract -d 3M2S+T,3M2S+T $r1 $r2 \\
	|sentieon bwa mem \\
		-R "@RG\\tID:$id\\tSM:$id\\tLB:$id\\tPL:illumina" \\
		-t ${task.cpus} \\
		-p -C $genome_file - \\
	|tee -a noumi.sam \\
	|sentieon umi consensus -o consensus.fastq.gz

	sentieon bwa mem \\
		-R "@RG\\tID:$id\\tSM:$id\\tLB:$id\\tPL:illumina" \\
		-t ${task.cpus} \\
		-p -C $genome_file consensus.fastq.gz \\
	|sentieon util sort -i - \\
		-o ${id}.${type}.bwa.umi.sort.bam \\
		--sam2bam

	sentieon util sort -i noumi.sam -o ${id}.${type}.bwa.sort.bam --sam2bam
	rm noumi.sam

	touch dedup_metrics.txt
	"""
}


process bwa_align {
	cpus params.cpu_all
	memory '64 GB'
	time '2h'
	tag "$id"
	    
	input: 
		set group, id, type, file(r1), file(r2) from fastq_noumi

	output:
		set group, id, type, file("${id}.${type}.bwa.sort.bam"), file("${id}.${type}.bwa.sort.bam.bai") into bam_markdup

	when:
		!params.umi

	script:

		if( params.sentieon_bwa ) {
			"""
			sentieon bwa mem -M -R '@RG\\tID:${id}\\tSM:${id}\\tPL:illumina' -t ${task.cpus} $genome_file $r1 $r2 \\
			| sentieon util sort -r $genome_file -o ${id}.${type}.bwa.sort.bam -t ${task.cpus} --sam2bam -i -
			"""
		}

		else {
			"""
			bwa mem -R '@RG\\tID:${id}\\tSM:${id}\\tPL:illumina' -M -t ${task.cpus} $genome_file $r1 $r2 \\
			| samtools view -Sb - \\
			| samtools sort -o ${id}.${type}.bwa.sort.bam -

			samtools index ${id}.${type}.bwa.sort.bam
			"""
		}
}


process markdup {
	publishDir "${OUTDIR}/bam", mode: 'copy', overwrite: true
	cpus params.cpu_many
	memory '64 GB'
	time '1h'
	tag "$id"
	scratch true
	stageInMode 'copy'
	stageOutMode 'copy'
    
	input:
		set group, id, type, file(bam), file(bai) from bam_markdup.mix(bam_umi_markdup)

	output:
		set group, id, type, file("${id}.${type}.dedup.bam"), file("${id}.${type}.dedup.bam.bai") into bam_bqsr
		set group, id, type, file("${id}.${type}.dedup.bam"), file("${id}.${type}.dedup.bam.bai"), file("dedup_metrics.txt") into bam_qc, bam_bqsr2, bam_lowcov

	"""
	sentieon driver -t ${task.cpus} -i $bam --algo LocusCollector --fun score_info score.gz
	sentieon driver -t ${task.cpus} -i $bam --algo Dedup --score_info score.gz --metrics dedup_metrics.txt ${id}.${type}.dedup.bam
	"""
}

// FIXME: Temporarily broke the non-UMI track since bam_umi_bqsr
//        and bam_bqsr collide here for UMI track. Figure out how
//        to use only bam_umi_bqsr when params.umi==true
process bqsr_umi {
	cpus params.cpu_some
	memory '16 GB'
	time '1h'
	tag "$id"
	scratch true
	stageInMode 'copy'
	stageOutMode 'copy'

	input:
		set group, id, type, file(bam), file(bai) from bam_umi_bqsr

	output:
		set group, id, type, file(bam), file(bai), file("${id}.bqsr.table") into bam_freebayes, bam_vardict, bam_tnscope, bam_cnvkit, bam_varli
	when:
		params.umi

	"""
	sentieon driver -t ${task.cpus} -r $genome_file -i $bam --algo QualCal ${id}.bqsr.table
	"""
}

process bqsr_to_constitutional {
	cpus params.cpu_some
	memory '16 GB'
	time '1h'
	tag "$id"
	publishDir "${OUTDIR}/bqsr", mode: 'copy', overwrite: true, pattern: '*.bqsr*'
	publishDir "${OUTDIR}/csv", mode: 'copy', overwrite: true, pattern: '*.csv*'
	//scratch true
	//stageInMode 'copy'
	//stageOutMode 'copy'

	when:
		mode == "neverever"

	input:
		set group, id, type, file(bam), file(bai), file(dedup), cid, poolid from bam_bqsr2.join(meta_const, by: [0,1,2]).filter{ item -> item[2] == 'N'}

	output:
		set group, id, type, file(bam), file(bai), file("${id}.const.bqsr") into input_const
		file("${id}.const.csv") into csv_const

	"""
	sentieon driver -t ${task.cpus} -r $genome_file -i $bam --algo QualCal ${id}.const.bqsr
	cat $params.const_csv_template > ${id}.const.csv
	echo $cid,$id,proband,oncov1-0-test,M,ovarian-normal,affected,$id,,,$poolid,illumina,${OUTDIR}/bam/$bam,${OUTDIR}/bqsr/${id}.const.bqsr,,screening >> ${id}.const.csv
	/fs1/bjorn/bnf-scripts/start_nextflow_analysis.pl ${id}.const.csv
	"""
	
}

process sentieon_qc {
	cpus params.cpu_many
	memory '32 GB'
	publishDir "${OUTDIR}/QC", mode: 'copy', overwrite: 'true', pattern: '*.QC*'
	time '1h'
	tag "$id"
	scratch true
	stageInMode 'copy'
	stageOutMode 'copy'

	input:
		set group, id, type, file(bam), file(bai), file(dedup) from bam_qc

	output:
		set group, id, type, file(bam), file(bai), file("${id}_is_metrics.txt") into all_pindel, bam_manta, bam_melt, bam_delly
		set id, type, file("${id}_${type}.QC") into qc_cdm
		set group, id, type, file("${id}_${type}.QC") into qc_melt
		file("*.txt")

	"""
	sentieon driver \\
		--interval $params.regions_bed -r $genome_file -t ${task.cpus} -i ${bam} \\
		--algo MeanQualityByCycle mq_metrics.txt --algo QualDistribution qd_metrics.txt \\
		--algo GCBias --summary gc_summary.txt gc_metrics.txt --algo AlignmentStat aln_metrics.txt \\
		--algo InsertSizeMetricAlgo is_metrics.txt \\
		--algo CoverageMetrics --cov_thresh 1 --cov_thresh 10 --cov_thresh 30 --cov_thresh 100 --cov_thresh 250 --cov_thresh 500 cov_metrics.txt
	sentieon driver \\
		-r $genome_file -t ${task.cpus} -i ${bam} \\
		--algo HsMetricAlgo --targets_list $params.interval_list --baits_list $params.interval_list hs_metrics.txt

	cp is_metrics.txt ${id}_is_metrics.txt

	qc_sentieon.pl ${id}_${type} panel > ${id}_${type}.QC
	"""
}

process lowcov {
	cpus 1
	memory '5 GB'
	publishDir "${OUTDIR}/QC", mode: 'copy', overwrite: 'true'
	time '1h'
	tag "$id"

	input:
		set group, id, type, file(bam), file(bai), file(dedup) from bam_lowcov


	output:
		set group, type, file("${id}.lowcov.bed") into lowcov_coyote

	"""
	panel_depth.pl $bam $params.regions_proteincoding > lowcov.bed
	overlapping_genes.pl lowcov.bed $params.gene_regions > ${id}.lowcov.bed
	"""
}

// Load QC data into CDM (via middleman)
process qc_to_cdm {
	cpus 1
	publishDir "${CRONDIR}/qc", mode: 'copy' , overwrite: 'true'
	tag "$id"
	time '10m'
	memory '50 MB'

	input:
		set id, type, file(qc), r1, r2 from qc_cdm.join(meta_qc)

	output:
		file("${id}.cdm") into cdm_done

	when:
		!params.noupload

	script:
		parts = r1.split('/')
		idx =  parts.findIndexOf {it ==~ /......_......_...._........../}
		rundir = parts[0..idx].join("/")

	"""
	echo "--run-folder $rundir --sample-id $id --assay GMSmyeloid --qc ${OUTDIR}/QC/${id}_${type}.QC" > ${id}.cdm
	"""
}

process qc_values {
	tag "$id"
	time '2m'
	memory '50 MB'
	tag "$id"

	input:
		set group, id, type, qc from qc_melt

	output:
		set group, id, type, val(INS_SIZE), val(MEAN_DEPTH), val(COV_DEV) into qc_melt_val
		set group, id, val(INS_SIZE), val(MEAN_DEPTH), val(COV_DEV) into qc_cnvkit_val
	
	script:
		// Collect qc-data if possible from normal sample, if only tumor; tumor
		qc.readLines().each{
			if (it =~ /\"(ins_size_dev)\" : \"(\S+)\"/) {
				ins_dev = it =~ /\"(ins_size_dev)\" : \"(\S+)\"/
			}
			if (it =~ /\"(mean_coverage)\" : \"(\S+)\"/) {
				coverage = it =~ /\"(mean_coverage)\" : \"(\S+)\"/
			}
			if (it =~ /\"(ins_size)\" : \"(\S+)\"/) {
				ins_size = it =~ /\"(ins_size)\" : \"(\S+)\"/
			}
		}
		// might need to be defined for -resume to work "def INS_SIZE" and so on....
		INS_SIZE = ins_size[0][2]
		MEAN_DEPTH = coverage[0][2]
		COV_DEV = ins_dev[0][2]
		"""
		echo $INS_SIZE $MEAN_DEPTH $COV_DEV > qc.val
		"""
}

process freebayes {
	cpus 1
	time '40m'
	tag "$group"
	
	input:
		set group, id, type, file(bams), file(bais), file(bqsr) from bam_freebayes.groupTuple()
		each file(bed) from beds_freebayes

	output:
		set val("freebayes"), group, file("freebayes_${bed}.vcf") into vcfparts_freebayes

	when:
		params.freebayes

	script:
		if( mode == "paired" ) {

			tumor_idx = type.findIndexOf{ it == 'tumor' || it == 'T' }
			normal_idx = type.findIndexOf{ it == 'normal' || it == 'N' }

			"""
			freebayes -f $genome_file -t $bed --pooled-continuous --pooled-discrete --min-repeat-entropy 1 -F 0.03 ${bams[tumor_idx]} ${bams[normal_idx]} > freebayes_${bed}.vcf.raw
			vcffilter -F LowCov -f "DP > 500" -f "QA > 1500" freebayes_${bed}.vcf.raw | vcffilter -F LowFrq -o -f "AB > 0.05" -f "AB = 0" | vcfglxgt > freebayes_${bed}.filt1.vcf
			filter_freebayes_somatic.pl freebayes_${bed}.filt1.vcf ${id[tumor_idx]} ${id[normal_idx]} > freebayes_${bed}.vcf
			"""
		}
		else if( mode == "unpaired" ) {
			"""
			freebayes -f $genome_file -t $bed --pooled-continuous --pooled-discrete --min-repeat-entropy 1 -F 0.03 $bams > freebayes_${bed}.vcf.raw
			vcffilter -F LowCov -f "DP > 500" -f "QA > 1500" freebayes_${bed}.vcf.raw | vcffilter -F LowFrq -o -f "AB > 0.05" -f "AB = 0" | vcfglxgt > freebayes_${bed}.filt1.vcf
			filter_freebayes_unpaired.pl freebayes_${bed}.filt1.vcf > freebayes_${bed}.vcf
			"""
		}
}


process vardict {
	cpus 1
	time '2h'
	tag "$group"
	memory '15GB'

	input:
		set group, id, type, file(bams), file(bais), file(bqsr) from bam_vardict.groupTuple()
		each file(bed) from beds_vardict

	output:
		set val("vardict"), group, file("vardict_${bed}.vcf") into vcfparts_vardict

	when:
		params.vardict
    
	script:
		if( mode == "paired" ) {

			tumor_idx = type.findIndexOf{ it == 'tumor' || it == 'T' }
			normal_idx = type.findIndexOf{ it == 'normal' || it == 'N' }

			"""
			vardict-java -G $genome_file -f 0.01 -N ${id[tumor_idx]} -b "${bams[tumor_idx]}|${bams[normal_idx]}" -c 1 -S 2 -E 3 -g 4 -U $bed \\
			| testsomatic.R | var2vcf_paired.pl -N "${id[tumor_idx]}|${id[normal_idx]}" -f 0.01 > vardict_${bed}.vcf.raw

			filter_vardict_somatic.pl vardict_${bed}.vcf.raw ${id[tumor_idx]} ${id[normal_idx]} > vardict_${bed}.vcf
			"""
		}
		else if( mode == "unpaired" ) {
			"""
			vardict-java -G $genome_file -f 0.03 -N ${id[0]} -b ${bams[0]} -c 1 -S 2 -E 3 -g 4 -U $bed | teststrandbias.R | var2vcf_valid.pl -N ${id[0]} -E -f 0.01 > vardict_${bed}.vcf.raw
			filter_vardict_unpaired.pl vardict_${bed}.vcf.raw > vardict_${bed}.vcf
			"""
		}
}


process tnscope {
	cpus params.cpu_some
	time '2h'   
	tag "$group" 

	input:
		set group, id, type, file(bams), file(bais), file(bqsr) from bam_tnscope.groupTuple()
		each file(bed) from beds_tnscope

	output:
		set val("tnscope"), group, file("tnscope_${bed}.vcf") into vcfparts_tnscope

	when:
		params.tnscope

	script:
		tumor_idx = type.findIndexOf{ it == 'tumor' || it == 'T' }
		normal_idx = type.findIndexOf{ it == 'normal' || it == 'N' }

		if( mode == 'paired' ) {
			"""
			sentieon driver -t ${task.cpus} \\
				-r $genome_file \\
				-i ${bams[tumor_idx]} -q ${bqsr[tumor_idx]} \\
				-i ${bams[normal_idx]} -q ${bqsr[normal_idx]} \\
				--interval $bed --algo TNscope \\
				--tumor_sample ${id[tumor_idx]} --normal_sample ${id[normal_idx]} \\
				--clip_by_minbq 1 --max_error_per_read 3 --min_init_tumor_lod 2.0 \\
				--min_base_qual 10 --min_base_qual_asm 10 --min_tumor_allele_frac 0.0005 \\
				tnscope_${bed}.vcf.raw

			filter_tnscope_somatic.pl tnscope_${bed}.vcf.raw ${id[tumor_idx]} ${id[normal_idx]} > tnscope_${bed}.vcf

			"""
		}
		else {
			"""
			sentieon driver -t ${task.cpus} -r $genome_file \\
				-i ${bams} -q ${bqsr} \\
				--interval $bed --algo TNscope \\
				--tumor_sample ${id[0]} \\
				--clip_by_minbq 1 --max_error_per_read 3 --min_init_tumor_lod 2.0 \\
				--min_base_qual 10 --min_base_qual_asm 10 --min_tumor_allele_frac 0.0005 \\
				tnscope_${bed}.vcf.raw

			filter_tnscope_unpaired.pl tnscope_${bed}.vcf.raw > tnscope_${bed}.vcf
			""" 
		}
}


process pindel {
	cpus params.cpu_some
	time '1h'
	publishDir "${OUTDIR}/vcf", mode: 'copy', overwrite: true
	tag "$group"

	input:
		set group, id, type, file(bams), file(bais), file(ins_size) from all_pindel.groupTuple()

	output:
		set group, val("pindel"), file("${group}_pindel.vcf") into vcf_pindel

	when:
		params.pindel

	script:
		if( mode == "paired" ) {
			tumor_idx = type.findIndexOf{ it == 'tumor' || it == 'T' }
			normal_idx = type.findIndexOf{ it == 'normal' || it == 'N' }
			ins_tumor = ins_size[tumor_idx]
			ins_normal = ins_size[normal_idx]
			bam_tumor = bams[tumor_idx]
			bam_normal = bams[normal_idx]
			id_tumor = id[tumor_idx]
			id_normal = id[normal_idx]

			"""
			INS_T="\$(sed -n '3p' $ins_tumor | cut -f 1 | awk '{print int(\$1+0.5)}')"
			INS_N="\$(sed -n '3p' $ins_normal | cut -f 1 | awk '{print int(\$1+0.5)}')"
			echo "$bam_tumor\t\$INS_T\t$id_tumor" > pindel_config
			echo "$bam_normal\t\$INS_N\t$id_normal" >> pindel_config

			pindel -f $genome_file -w 0.1 -x 2 -i pindel_config -j $params.pindel_regions_bed -o tmpout -T ${task.cpus}
			pindel2vcf -P tmpout -r $genome_file -R hg19 -d 2015-01-01 -v ${group}_pindel_unfilt.vcf -is 10 -e 30 -he 0.01
			filter_pindel_somatic.pl ${group}_pindel_unfilt.vcf ${group}_pindel.vcf
			"""
		}
		else {
			tumor_idx = type.findIndexOf{ it == 'tumor' || it == 'T' }
			ins_tumor = ins_size[tumor_idx]
			bam_tumor = bams[tumor_idx]
			id_tumor = id[tumor_idx]

			"""
			INS_T="\$(sed -n '3p' $ins_tumor | cut -f 1 | awk '{print int(\$1+0.5)}')"
			echo "$bam_tumor\t\$INS_T\t$id_tumor" > pindel_config

			pindel -f $genome_file -w 0.1 -x 2 -i pindel_config -j $params.pindel_regions_bed -o tmpout -T ${task.cpus}
			pindel2vcf -P tmpout -r $genome_file -R hg19 -d 2015-01-01 -v ${group}_pindel_unfilt.vcf -is 10 -e 30 -he 0.01
			filter_pindel_somatic.pl ${group}_pindel_unfilt.vcf ${group}_pindel.vcf
			"""
		}

}


// Prepare vcf parts for concatenation
vcfparts_freebayes = vcfparts_freebayes.groupTuple(by:[0,1])
vcfparts_tnscope   = vcfparts_tnscope.groupTuple(by:[0,1])
vcfparts_vardict   = vcfparts_vardict.groupTuple(by:[0,1])
vcfs_to_concat = vcfparts_freebayes.mix(vcfparts_vardict).mix(vcfparts_tnscope)

process concatenate_vcfs {
	cpus 1
	publishDir "${OUTDIR}/vcf", mode: 'copy', overwrite: true
	time '20m'    
	tag "$group"

	input:
		set vc, group, file(vcfs) from vcfs_to_concat

	output:
		set group, vc, file("${group}_${vc}.vcf.gz") into concatenated_vcfs, vcf_cnvkit

	"""
	vcf-concat $vcfs | vcf-sort -c | gzip -c > ${vc}.concat.vcf.gz
	vt decompose ${vc}.concat.vcf.gz -o ${vc}.decomposed.vcf.gz
	vt normalize ${vc}.decomposed.vcf.gz -r $genome_file | vt uniq - -o ${group}_${vc}.vcf.gz
	"""
}


process cnvkit {
	publishDir "${OUTDIR}/vcf", mode: 'copy', overwrite: true, pattern: '*.vcf'
	cpus 1
	time '1h'
	tag "$id"
	scratch true
	stageInMode 'copy'
	stageOutMode 'copy'
	
	input:
		set gr, id, type, file(bam), file(bai), file(bqsr), val(INS_SIZE), val(MEAN_DEPTH), val(COV_DEV),g ,vc, file(vcf) from bam_cnvkit.join(qc_cnvkit_val, by:[0,1]) \
			.combine(vcf_cnvkit.filter { item -> item[1] == 'freebayes' })
		
	output:
		set gr, id, type, file("${gr}.${id}.cnvkit_overview.png"), file("${gr}.${id}.call.cns"), file("${gr}.${id}.cnr"), file("${gr}.${id}.filtered") into geneplot_cnvkit
		set gr, id, type, file("${gr}.${id}.filtered.vcf") into cnvkit_vcf 
		file("${gr}.${id}.cns") into cns_notcalled

	when:
		params.cnvkit

	script:
		freebayes_idx = vc.findIndexOf{ it == 'freebayes' }

	"""
	cnvkit.py batch $bam -r $params.cnvkit_reference -d results/
	cnvkit.py call results/*.cns -v $vcf -o ${gr}.${id}.call.cns
	filter_cnvkit.pl ${gr}.${id}.call.cns $MEAN_DEPTH > ${gr}.${id}.filtered
	cnvkit.py export vcf ${gr}.${id}.filtered -i "$id" > ${gr}.${id}.filtered.vcf		
	cnvkit.py scatter -s results/*.cn{s,r} -o ${gr}.${id}.cnvkit_overview.png -v ${vcf[freebayes_idx]} -i $id
	cp results/*.cnr ${gr}.${id}.cnr
	cp results/*.cns ${gr}.${id}.cns
	"""
}

// Plot specific gene-regions. CNVkit 0.9.6 and forward introduced a bug in region plot, use 0.9.5 (091 wrong name, container has 0.9.5)
process gene_plot {
	publishDir "${OUTDIR}/plots", mode: 'copy', overwrite: true, pattern: '*.png'
	cpus 1
	container = '/fs1/resources/containers/cnvkit91_montage.sif'
	time '5m'
	tag "$id"

	input:
		set gr, id, type, file(overview), file(cns), file(cnr), file(filtered) from geneplot_cnvkit

	output:
		set gr, id, type, file("${gr}.${id}.cnvkit.png") into cnvplot_coyote

	script:

		if (params.assay == "ovarian") {
			"""
			cnvkit.py scatter -s $cns $cnr -c 13:32165479-32549672 -o brca2.png --title 'BRCA2'
			cnvkit.py scatter -s $cns $cnr -c 17:42894294-43350132 -o brca1.png --title 'BRCA1'
			montage -mode concatenate -tile 1x *.png ${gr}.${id}.cnvkit.png
			"""		
		}
		else {
			"""
			mv ${gr}.${id}.cnvkit_overview.png ${gr}.${id}.cnvkit.png
			"""
		}


}

process melt {
	publishDir "${OUTDIR}/vcf", mode: 'copy', overwrite: true
	cpus 2
	//container = '/fs1/resources/containers/container_twist-brca.sif'
	memory '10 GB'
	tag "$group"
	scratch true
	stageInMode 'copy'
	stageOutMode 'copy'


	input:
		set group, id, type, file(bam), file(bai), file(bqsr), val(INS_SIZE), val(MEAN_DEPTH), val(COV_DEV) from bam_melt \
			.join(qc_melt_val, by: [0,1,2])
		
	when:
		params.melt

	output:
		set group, id, type, file("${id}.melt.merged.vcf") into melt_vcf

	"""
	set +eu
	source activate java8-env
	set -eu
	java -jar  /opt/MELT.jar Single \\
		-bamfile $bam \\
		-r 150 \\
		-h $genome_file \\
		-n $params.bed_melt \\
		-z 50000 \\
		-d 50 -t $params.mei_list \\
		-w . \\
		-b 1/2/3/4/5/6/7/8/9/10/11/12/14/15/16/18/19/20/21/22 \\
		-c $MEAN_DEPTH \\
		-cov $COV_DEV \\
		-e $INS_SIZE
	source deactivate
	merge_melt.pl $params.meltheader $id
	"""

}

// MANTA SINGLE AND PAIRED
process manta {
	publishDir "${OUTDIR}/vcf", mode: 'copy', overwrite: true
	cpus 16
	time '10h'
	//container = '/fs1/resources/containers/wgs_2020-03-25.sif'
	tag "$group"
	scratch true
	stageInMode 'copy'
	stageOutMode 'copy'
	
	input:
		set group, id, type, file(bam), file(bai), file(bqsr) from bam_manta.groupTuple()

	output:
		set group, file("${group}_manta.vcf") into manta_vcf

	when:
		params.manta
	
	script:
		if(mode == "paired") { 
			tumor_idx = type.findIndexOf{ it == 'tumor' || it == 'T' }
			normal_idx = type.findIndexOf{ it == 'normal' || it == 'N' }
			normal = bam[normal_idx]
			normal_id = id[normal_idx]
			tumor = bam[tumor_idx]
			tumor_id = id[tumor_idx]

			"""
			configManta.py \\
				--tumorBam $tumor \\
				--normalBam $normal \\
				--reference $genome_file \\
				--exome \\
				--callRegions $params.bedgz \\
				--generateEvidenceBam \\
				--runDir .
			python runWorkflow.py -m local -j ${task.cpus}
			#filter_manta_paired.pl results/variants/somaticSV.vcf.gz > ${group}_manta.vcf
			mv results/variants/somaticSV.vcf.gz ${group}_manta.vcf.gz
			gunzip ${group}_manta.vcf.gz
			"""
		}
		else {
			"""
			configManta.py \\
				--tumorBam $bam \\
				--reference $genome_file \\
				--exome \\
				--callRegions $params.bedgz \\
				--generateEvidenceBam \\
				--runDir .
			python runWorkflow.py -m local -j ${task.cpus}
			#filter_manta.pl results/variants/tumorSV.vcf.gz > ${group}_manta.vcf
			mv results/variants/tumorSV.vcf.gz ${group}_manta.vcf.gz
			gunzip ${group}_manta.vcf.gz
			"""
		}
}

// Delly SINGLE AND PAIRED
process delly {
	publishDir "${OUTDIR}/vcf", mode: 'copy', overwrite: true
	cpus 2
	time '20h'
	//container = '/fs1/resources/containers/wgs_2020-03-25.sif'
	tag "$group"
		
	input:
		set group, id, type, file(bam), file(bai), file(bqsr) from bam_delly.groupTuple()

	output:
		set group, file("${group}.delly.filtered.vcf") into delly_vcf

	when:
		params.manta
	
	script:
		if(mode == "paired") { 
			tumor_idx = type.findIndexOf{ it == 'tumor' || it == 'T' }
			normal_idx = type.findIndexOf{ it == 'normal' || it == 'N' }
			normal = bam[normal_idx]
			normal_id = id[normal_idx]
			tumor = bam[tumor_idx]
			tumor_id = id[tumor_idx]

			"""
			delly call -g $genome_file -o ${group}.delly.bcf $tumor $normal
			bcftools view ${group}.delly.bcf > ${group}.delly.vcf
			filter_delly.pl --vcf ${group}.delly.vcf --bed $params.regions_bed > ${group}.delly.filtered.vcf
			"""
		}
		else {
			"""
			delly call -g $genome_file -o ${group}.delly.bcf $bam
			bcftools view ${group}.delly.bcf > ${group}.delly.vcf
			filter_delly.pl --vcf ${group}.delly.vcf --bed $params.regions_bed > ${group}.delly.filtered.vcf
			"""
		}
}

process concat_cnv {
	cpus 1
	memory '1GB'
	publishDir "${OUTDIR}/vcf", mode: 'copy', overwrite: true
	//container = '/fs1/resources/containers/wgs_2020-03-25.sif'
	time '20m'
	tag "$group"

	input:
		set group, file(mantavcf) from manta_vcf
		set group, file(dellyvcf) from delly_vcf
		set g_c, id_c, type_c, file(cnvkitvcf), tissue_c from cnvkit_vcf.join(meta_cnvkit, by:[0,1,2]).groupTuple()
		set g_m, id_m, type_m, file(meltvcf), tissue_m from melt_vcf.join(meta_melt, by:[0,1,2]).groupTuple()


	output:
		file("${group}.cnvs.agg.vcf") into cnvs
	
	script:
	
	if (mode == 'paired') {
		tumor_idx_c = type_c.findIndexOf{ it == 'tumor' || it == 'T' }
		tumor_idx_m = type_m.findIndexOf{ it == 'tumor' || it == 'T' }
		normal_idx_c = type_c.findIndexOf{ it == 'normal' || it == 'N' }
		normal_idx_m = type_m.findIndexOf{ it == 'normal' || it == 'N' }
		if (tissue_c[tumor_idx_c] == 'ffpe') {
			cnvkitvcf = cnvkitvcf[normal_idx_c]
			meltvcf = meltvcf[normal_idx_m]
		}
		else {
			cnvkitvcf = cnvkitvcf[tumor_idx_c]
			meltvcf = meltvcf[tumor_idx_m]

		}
		tmp = mantavcf.collect {it + ':manta ' } + dellyvcf.collect {it + ':delly ' } + cnvkitvcf.collect {it + ':cnvkit ' }
		vcfs = tmp.join(' ')
		"""
		set +eu
		source activate py3-env
		svdb --merge --vcf $vcfs --no_intra --pass_only --bnd_distance 2500 --overlap 0.7 --priority manta,delly,cnvkit > ${group}.merged.vcf
		aggregate_cnv2_vcf.pl --vcfs ${group}.merged.vcf,$meltvcf \\
			--tumor-id ${id_c[tumor_idx_c]} \\
			--normal-id ${id_c[normal_idx_c]} \\
			--paired paired \\
			--sample-order ${id_c[tumor_idx_c]},${id_c[normal_idx_c]} > ${group}.cnvs.agg.vcf
		"""
	}
	else {
		tmp = mantavcf.collect {it + ':manta ' } + dellyvcf.collect {it + ':delly ' } + cnvkitvcf.collect {it + ':cnvkit ' }
		vcfs = tmp.join(' ')
		"""
		set +eu
		source activate py3-env
		svdb --merge --vcf $vcfs --no_intra --pass_only --bnd_distance 2500 --overlap 0.7 --priority manta,delly,cnvkit > ${group}.merged.vcf
		aggregate_cnv2_vcf.pl --vcfs ${group}.merged.vcf,$meltvcf --paired no > ${group}.cnvs.agg.vcf
		"""
		
	}

}

process aggregate_vcfs {
	cpus 1
	publishDir "${OUTDIR}/vcf", mode: 'copy', overwrite: true
	time '20m'
	tag "$group"

	input:
		set group, vc, file(vcfs) from concatenated_vcfs.mix(vcf_pindel).groupTuple()
		set g, id, type, tissue from meta_aggregate.groupTuple()
		file(cnvs) from cnvs.ifEmpty("nocnvs")

	output:
		set group, file("${group}.agg.vcf") into vcf_pon, vcf_done

	script:
		sample_order = id[0]
		if( mode == "paired" ) {
			tumor_idx = type.findIndexOf{ it == 'tumor' || it == 'T' }
			normal_idx = type.findIndexOf{ it == 'normal' || it == 'N' }
			sample_order = id[tumor_idx]+","+id[normal_idx]
		}
		if (params.assay == 'myeloid') {
			"""
			aggregate_vcf.pl --vcf ${vcfs.sort(false) { a, b -> a.getBaseName() <=> b.getBaseName() }.join(",")} --sample-order ${sample_order} |vcf-sort -c > ${group}.agg.vcf
			"""
		}
		else {
			"""
			aggregate_vcf.pl --vcf ${vcfs.sort(false) { a, b -> a.getBaseName() <=> b.getBaseName() }.join(",")} --sample-order ${sample_order} |vcf-sort -c > ${group}.agg.tmp.vcf
			vcf-concat ${group}.agg.tmp.vcf $cnvs | vcf-sort -c > ${group}.agg.vcf
			"""
		}

}

process pon_filter {
	publishDir "${OUTDIR}/vcf", mode: 'copy', overwrite: true
	cpus 1
	time '1h'
	tag "$group"
	memory '32 GB'

	input:
		set group, file(vcf) from vcf_pon
		set g, id, type, tissue from meta_pon.groupTuple()

	output:
		set group, file("${group}.agg.pon.vcf") into vcf_vep

	script:
	if (params.assay == 'myeloid') {
			def pons = []
			if( params.freebayes ) { pons.push("freebayes="+params.PON_freebayes) }
			if( params.vardict )   { pons.push("vardict="+params.PON_vardict) }
			if( params.tnscope )   { pons.push("tnscope="+params.PON_tnscope) }
			def pons_str = pons.join(",")
			tumor_idx = type.findIndexOf{ it == 'tumor' || it == 'T' }

		"""
		filter_with_pon.pl --vcf $vcf --pons $pons_str --tumor-id ${id[tumor_idx]} > ${group}.agg.pon.vcf
		"""
	}
	else if (params.assay == 'ovarian') {
		"""
		vcfanno_linux64 -lua /fs1/resources/ref/hg19/bed/scout/sv_tracks/silly.lua $params.vcfanno $vcf > ${group}.agg.pon.vcf
		"""
	}
}

process annotate_vep {
	container = params.vepcon
	publishDir "${OUTDIR}/vcf", mode: 'copy', overwrite: true
	cpus params.cpu_many
	time '1h'
	tag "$group"
    
	input:
		set group, file(vcf) from vcf_vep
    
	output:
		set group, file("${group}.agg.pon.vep.vcf") into vcf_germline

	"""
	vep -i ${vcf} -o ${group}.agg.pon.vep.vcf \\
	--offline --merged --everything --vcf --no_stats \\
	--fork ${task.cpus} \\
	--force_overwrite \\
	--plugin CADD $params.CADD --plugin LoFtool \\
	--fasta $params.VEP_FASTA \\
	--dir_cache $params.VEP_CACHE --dir_plugins $params.VEP_CACHE/Plugins \\
	--distance 200 \\
	-cache -custom $params.GNOMAD \\
	"""
}

process mark_germlines {
	publishDir "${OUTDIR}/vcf", mode: 'copy', overwrite: true
	cpus params.cpu_many
	time '20m'
	tag "$group"

	input:
		set group, file(vcf) from vcf_germline
		set g, id, type, tissue from meta_germline.groupTuple()

	output:
		set group, file("${group}.agg.pon.vep.markgerm.vcf") into vcf_umi


	script:
		if( mode == "paired" ) {
			tumor_idx = type.findIndexOf{ it == 'tumor' || it == 'T' }
			normal_idx = type.findIndexOf{ it == 'normal' || it == 'N' }
			"""
			mark_germlines.pl --vcf $vcf --tumor-id ${id[tumor_idx]} --normal-id ${id[normal_idx]} --assay $params.assay > ${group}.agg.pon.vep.markgerm.vcf
			"""
		}
		else if( mode == "unpaired" ) {
			"""
			mark_germlines.pl --vcf $vcf --tumor-id ${id[0]} --assay $params.assay > ${group}.agg.pon.vep.markgerm.vcf
			"""
		}
}

process umi_confirm {
	publishDir "${OUTDIR}/vcf", mode: 'copy', overwrite: true
	cpus 2
	time '8h'
	tag "$group"

	when:
		params.umi

	input:
		set group, file(vcf) from vcf_umi
		set g, id, type, file(bam), file(bai) from bam_umi_confirm.groupTuple()

	output:
		set group, file("${group}.agg.pon.vep.markgerm.umi*") into vcf_coyote


	script:
		if (params.conform) {
	
			if( mode == "paired" ) {
				tumor_idx = type.findIndexOf{ it == 'tumor' || it == 'T' }
				normal_idx = type.findIndexOf{ it == 'normal' || it == 'N' }

				"""
				source activate samtools
				UMIconfirm_vcf.py ${bam[tumor_idx]} $vcf $genome_file ${id[tumor_idx]} > umitmp.vcf
				UMIconfirm_vcf.py ${bam[normal_idx]} umitmp.vcf $genome_file ${id[normal_idx]} > ${group}.agg.pon.vep.markgerm.umi.vcf
				"""
			}
			else if( mode == "unpaired" ) {
				tumor_idx = type.findIndexOf{ it == 'tumor' || it == 'T' }

				"""
				source activate samtools
				UMIconfirm_vcf.py ${bam[tumor_idx]} $vcf $genome_file ${id[tumor_idx]} > ${group}.agg.pon.vep.markgerm.umi.vcf
				"""
			}

		}
		else {
			"""
			cp $vcf ${group}.agg.pon.vep.markgerm.umino.vcf
			"""
		}
}


process coyote {
	publishDir "${params.crondir}/coyote", mode: 'copy', overwrite: true
	cpus 1
	time '10m'
	tag "$group"

	input:
		set group, file(vcf) from vcf_coyote
		set g, type, lims_id, pool_id from meta_coyote.groupTuple()
		set g2, id, cnv_type, file(cnvplot), tissue_c from cnvplot_coyote.join(meta_cnvplot, by:[0,1,2]).groupTuple()
		set g3, lowcov_type, file(lowcov) from lowcov_coyote.groupTuple()


	output:
		file("${group}.coyote")

	when:
		!params.noupload

	script:
		tumor_idx = type.findIndexOf{ it == 'tumor' || it == 'T' }
		tumor_idx_cnv = cnv_type.findIndexOf{ it == 'tumor' || it == 'T' }
		normal_idx_cnv = cnv_type.findIndexOf{ it == 'normal' || it == 'N' }
		cnv_index = tumor_idx_cnv
		if (params.assay == 'myeloid') {
			cnv_index = tumor_idx_cnv
		}
		else if (tissue_c[tumor_idx_cnv] == 'ffpe' || 'FFPE') {
			cnv_index = normal_idx_cnv
		}
		tumor_idx_lowcov = lowcov_type.findIndexOf{ it == 'tumor' || it == 'T' }

	"""
	echo "import_myeloid_to_coyote_vep_gms.pl --group $params.coyote_group \\
		--vcf /access/${params.assay}/vcf/${vcf} --id ${group} \\
		--cnv /access/${params.assay}/plots/${cnvplot[cnv_index]} \\
		--clarity-sample-id ${lims_id[tumor_idx]} \\
		--lowcov /access/myeloid/QC/${lowcov[tumor_idx_lowcov]} \\
		--clarity-pool-id ${pool_id[tumor_idx]}" > ${group}.coyote
	"""
}

#!/bin/bash
## Prepare job submission

if [ $# -ne 1 ]; then
    echo "@@@ Usage: $0 ARCHIVE.tgz"
    exit
fi
ARCHIVE=$1

######## Parameters to be defined by user ########
[ -z $SIF ] && SIF=/scratch/hpc22a02/singularity/mg5_amc_2.9.9.sif
[ -z $LHAPDFSETS ] && LHAPDFSETS=/scratch/hpc22a02/lhapdfsets/current
[ -z $NCPUS ] || export OMP_NUM_THREADS=$NCPUS

[ -z $JOBSTART ] && JOBSTART=1000
[ -z $NEVENT ] && NEVENT=10000
[ -z $NJOBS ] && NJOBS=10
[ -z $JOBPREFIX ] && JOBPREFIX=madgraph.
[ -z $JOBSUFFIX ] && JOBSUFFIX=""

####### ENVVARS automatically re-evaluated #######
## OMP_NUM_THREADS: for the case of NCPUS and OMP_NUM_THREADS undefined
[ -z $OMP_NUM_THREADS ] && export OMP_NUM_THREADS=64

############## Check environments ################
## Check singularity
IS_MOD_NEEDED=0
which singularity >& /dev/null
if [ $? -ne 0 ]; then
    which module >& /dev/null
    if [ $? -eq 0 ]; then
        module load singularity
        module load gcc/8.3.0
        module load mvapich2/2.3.6
        IS_MOD_NEEDED=1
    fi
fi
which singularity >& /dev/null
if [ $? -ne 0 ]; then
    echo "@@@ Singularity is not available. Stop."
    exit
fi

## Check singularity image
if [ ! -f $SIF ]; then
    echo "@@@ Singularity image file is not available. Stop."
    echo "    SIF=$SIF"
    exit
fi

## Check LHAPDF
if [ ! -d $LHAPDFSETS ]; then
    echo "@@@ LHAPDF is not available. Stop."
    echo "    LHAPDFSETS=$LHAPDFSETS"
    exit
fi

## Check archive tgz file
if [ ! -f $ARCHIVE ]; then
    echo "@@@ Generator archive file is not available. Stop."
    echo "    ARCHIVE=$ARCHIVE"
    exit
fi
ARBASE=`basename $ARCHIVE | sed -e 's;.tgz$;;g'`
ARCHIVE=`readlink -f $ARCHIVE`

###### Prepare job directory and run scripts ######
for IJOB in `seq $JOBSTART $(($JOBSTART+$NJOBS))`; do
    OUTDIR=${JOBPREFIX}.${ARBASE/.tgz/}.${JOBSUFFIX}.`printf %05d $IJOB`
    echo "@@@ Set output directory $OUTDIR"
    mkdir $OUTDIR
    cd $OUTDIR

    echo "@@@ Extracting archive file $ARBASE..."
    tar xzf $ARCHIVE

    echo "@@@ Writing run script..."
    cat > run.sh <<EOF
#!/bin/bash
#PBS -V
#PBS -q normal
#PBS -A etc
#PBS -N $OUTDIR
#PBS -l select=1:ncpus=$OMP_NUM_THREADS:mpiprocs=1:ompthreads=$OMP_NUM_THREADS
#PBS -l walltime=04:00:00

SIF=$SIF
export LHAPDFSETS=$LHAPDFSETS
export OMP_NUM_THREAD=$OMP_NUM_THREADS
export LHAPDF_DATA_PATH=/lhapdfsets
RUNNAME=`printf 'run_%04d' $IJOB`
SEED1=$IJOB
NEVENT=$NEVENT

env
echo -ne "NPROC="
nproc
echo "-------------------------"
EOF

    if [ $IS_MOD_NEEDED -eq 1 ]; then
        cat >> run.sh <<EOF
module load singularity
module load gcc/8.3.0
module load mvapich2/2.3.6
EOF
    fi

    cat >> run.sh <<EOF
cd $ARBASE
echo "@@@ Cleaning previously produced files..."
rm -f RunWeb ME5_debug

sed -ie 's;.*= *nevents.*$;'\$NEVENT' = nevents;g' $ARBASE/Cards/run_card.dat
sed -ie 's;.*= *iseed;'\$SEED1' = iseed;g' $ARBASE/Cards/run_card.dat

echo "@@@ Starting singularity session to run the mg5_amc"
EOF

    if [ -f $ARBASE/Cards/madspin_card.dat ]; then
        sed -ie "s;set max_running_process.*;set max_running_process $OMP_NUM_THREADS;g" $ARBASE/Cards/madspin_card.dat
    fi

    if [   -f $ARBASE/Cards/me5_configuration.txt -a \
         ! -f Cards/amcatnlo_configuration.txt ]; then
        echo "@@@ Madgraph (LO) configuration detected."
        sed -ie 's;.*run_mode *=.*$;run_mode = 2;g' $ARBASE/Cards/me5_configuration.txt
        sed -ie 's;.*nb_core.*=.*$;nb_core = '$OMP_NUM_THREADS';g' $ARBASE/Cards/me5_configuration.txt

        cat >> run.sh <<EOF
/usr/bin/time -f"\${OMP_NUM_THREADS},\${NEVENT},%e,%U,%S,%M" -a -o ../timelog.csv \
              singularity exec -B\$LHAPDFSETS:/lhapdfsets \
              \$SIF bin/generate_events \$RUNNAME <<EOF
1=OFF; 2=OFF; 3=OFF; 4=OFF; 5=OFF
0
\EOF
EOF

    elif [   -f $ARBASE/Cards/amcatnlo_configuration.txt -a \
           ! -f $ARBASE/Cards/me5_configuration.txt ]; then
        echo "@@@ aMC@NLO (NLO) configuration detected."
        sed -ie 's;.*run_mode *=.*$;run_mode = 2;g' $ARBASE/Cards/amcatnlo_configuration.txt
        sed -ie 's;.*nb_core.*=.*$;nb_core = '$OMP_NUM_THREADS';g' $ARBASE/Cards/amcatnlo_configuration.txt

        cat >> run.sh <<EOF
/usr/bin/time -f"\${OMP_NUM_THREADS},\${NEVENT},%e,%U,%S,%M" -a -o ../timelog.csv \
              singularity exec -B\$LHAPDFSETS:/lhapdfsets \
              \$SIF bin/generate_events -oxpMmf -n \$RUNNAME
EOF
    fi

    cat >> run.sh <<EOF
echo ARGS=$*
echo -ne "NPROC="
nproc

mv Events/* ../
cd ..
rm -rf $ARBASE
EOF

    chmod +x run.sh

    echo "nCPUs,nEvents,real,user,sys,maxRAM" > timelog.csv

    cd ..    
done

echo "@@@ Done"

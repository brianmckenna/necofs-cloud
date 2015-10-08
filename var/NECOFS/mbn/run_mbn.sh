#!/bin/sh
ulimit -s unlimited

if ! [ $RUNDIR ] && [ $HOSTS ] && [ $NPROCS ] && [ $START ] && [ $RUN_HOURS ]; then
    echo "The following environment variables must be set"
    echo "    \$RUNDIR"
    echo "    \$HOSTS"
    echo "    \$NPROCS"
    echo "    \$START"
    echo "    \$RUN_HOURS"
    exit
fi

END=`printf "%s +%d hours" $START $RUN_HOURS`
PLUS_ONE_HOUR=`printf "%s +1 hours" $START`

# FVCOM namelist date format
START_DATE=`date -d "${START}" "+%Y-%m-%d %H:%M:%S"`
END_DATE=`date -d "${END}" "+%Y-%m-%d %H:%M:%S"`
START_DATE_PLUS_ONE_HOUR=`date -d "${PLUS_ONE_HOUR}" "+%Y-%m-%d %H:%M:%S"`

# download restart file
cd $RUNDIR/mbn
curl -s -o input/mbn_restart.nc "http://54.86.86.177/thredds/fileServer/RESTART/MBN/Files/${START//-/}00.nc"

# dimensions on node_nest.nc
cd $RUNDIR/mbn/input
ncks -h -F -d siglay,1,40,4 -d siglev,1,41,4 node_nest.nc.template node_nest.nc

# MBN hotstart
cd $RUNDIR/mbn/run
sed "s/__START_DATE__/${START_DATE}/g" mbn_hot_run.nml.template > mbn_hot_run.nml
sed -i "s/__START_DATE_PLUS_ONE_HOUR__/${START_DATE_PLUS_ONE_HOUR}/g" mbn_hot_run.nml
mpiexec -mca plm_rsh_agent "/opt/necofs/bin/vpc-ssh" -host $HOSTS -n $NPROCS /opt/necofs/bin/fvcom_mbn --CASENAME=mbn_hot

ln -s $RUNDIR/mbn/output/mbn_hot_0001.nc $RUNDIR/mbn/output/mbn_for_0001.nc
ln -s $RUNDIR/mbn/output/mbn_hot_restart_0001.nc $RUNDIR/mbn/output/mbn_for_restart_0001.nc

# MBN forecast
cd $RUNDIR/mbn/run
sed "s/__START_DATE__/${START_DATE}/g" mbn_for_run.nml.template > mbn_for_run.nml
sed -i "s/__END_DATE__/${END_DATE}/g" mbn_for_run.nml
mpiexec -mca plm_rsh_agent "/opt/necofs/bin/vpc-ssh" -host $HOSTS -n $NPROCS /opt/necofs/bin/fvcom_mbn --CASENAME=mbn_for

# copy output to S3 bucket
aws s3 cp $RUNDIR/mbn/output/mbn_for_0001.nc s3://necofs/output/necofs_mbn_${START}.nc
aws s3 cp $RUNDIR/mbn/output/mbn_for_restart_0001.nc s3://necofs/output/necofs_mbn_restart_${START}.nc

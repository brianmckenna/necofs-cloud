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

# download restart file from cloud TDS server (running on Amazon) NOTE: IP is Elastic IP
cd $RUNDIR/gom
curl -s -o input/gom_restart.nc "http://54.86.86.177/thredds/fileServer/RESTART/GOM/Files/${START//-/}00.nc"

# GOM hotstart
cd $RUNDIR/gom/run
sed "s/__START_DATE__/${START_DATE}/g" gom_hot_run.nml.template > gom_hot_run.nml
sed -i "s/__START_DATE_PLUS_ONE_HOUR__/${START_DATE_PLUS_ONE_HOUR}/g" gom_hot_run.nml
mpiexec -mca plm_rsh_agent "/opt/necofs/bin/vpc-ssh" -host $HOSTS -n $NPROCS /opt/necofs/bin/fvcom_gom --CASENAME=gom_hot

ln -s $RUNDIR/gom/output/gom_hot_0001.nc $RUNDIR/gom/output/gom_for_0001.nc
ln -s $RUNDIR/gom/output/gom_hot_restart_0001.nc $RUNDIR/gom/output/gom_for_restart_0001.nc

# GOM forecast
cd $RUNDIR/gom/run
sed "s/__START_DATE__/${START_DATE}/g" gom_for_run.nml.template > gom_for_run.nml
sed -i "s/__END_DATE__/${END_DATE}/g" gom_for_run.nml
mpiexec -mca plm_rsh_agent "/opt/necofs/bin/vpc-ssh" -host $HOSTS -n $NPROCS /opt/necofs/bin/fvcom_gom --CASENAME=gom_for

# copy output to S3 bucket
aws s3 cp $RUNDIR/gom/output/gom_for_0001.nc s3://necofs/output/necofs_gom_${START}.nc
aws s3 cp $RUNDIR/gom/output/gom_for_restart_0001.nc s3://necofs/output/necofs_gom_restart_${START}.nc

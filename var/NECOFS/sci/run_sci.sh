#!/bin/sh
set -x
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
cd $RUNDIR/sci
curl -s -o input/sci_restart.nc "http://54.86.86.177/thredds/fileServer/RESTART/SCI/Files/${START//-/}00.nc"

# dimensions on node_nest.nc
cd $RUNDIR/sci/input
ncks -h -F -d siglay,1,40,4 -d siglev,1,41,4 node_nest.nc.template node_nest.nc

# GOM hotstart
cd $RUNDIR/sci/run
sed "s/__START_DATE__/${START_DATE}/g" sci_hot_run.nml.template > sci_hot_run.nml
sed -i "s/__START_DATE_PLUS_ONE_HOUR__/${START_DATE_PLUS_ONE_HOUR}/g" sci_hot_run.nml
mpiexec -mca plm_rsh_agent "/opt/necofs/bin/vpc-ssh" -host $HOSTS -n $NPROCS /opt/necofs/bin/fvcom_sci --CASENAME=sci_hot

ln -s $RUNDIR/sci/output/sci_hot_0001.nc $RUNDIR/sci/output/sci_for_0001.nc
ln -s $RUNDIR/sci/output/sci_hot_restart_0001.nc $RUNDIR/sci/output/sci_for_restart_0001.nc

# GOM forecast
cd $RUNDIR/sci/run
sed "s/__START_DATE__/${START_DATE}/g" sci_for_run.nml.template > sci_for_run.nml
sed -i "s/__END_DATE__/${END_DATE}/g" sci_for_run.nml
mpiexec -mca plm_rsh_agent "/opt/necofs/bin/vpc-ssh" -host $HOSTS -n $NPROCS /opt/necofs/bin/fvcom_sci --CASENAME=sci_for

# copy output to S3 bucket
aws s3 cp $RUNDIR/sci/output/sci_for_0001.nc s3://necofs/output/necofs_sci_${START}.nc
aws s3 cp $RUNDIR/sci/output/sci_for_restart_0001.nc s3://necofs/output/necofs_sci_restart_${START}.nc

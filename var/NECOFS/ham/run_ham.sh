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
cd $RUNDIR/ham
curl -s -o input/ham_restart.nc "http://54.86.86.177/thredds/fileServer/RESTART/HAM/Files/${START//-/}00.nc"

# dimensions on node_nest.nc
cd $RUNDIR/ham/input
ncks -h -F -d siglay,1,40,4 -d siglev,1,41,4 node_nest.nc.template node_nest.nc

# GOM hotstart
cd $RUNDIR/ham/run
sed "s/__START_DATE__/${START_DATE}/g" ham_hot_run.nml.template > ham_hot_run.nml
sed -i "s/__START_DATE_PLUS_ONE_HOUR__/${START_DATE_PLUS_ONE_HOUR}/g" ham_hot_run.nml
mpiexec -mca plm_rsh_agent "/opt/necofs/bin/vpc-ssh" -host $HOSTS -n $NPROCS /opt/necofs/bin/fvcom_ham --CASENAME=ham_hot

ln -s $RUNDIR/ham/output/ham_hot_0001.nc $RUNDIR/ham/output/ham_for_0001.nc
ln -s $RUNDIR/ham/output/ham_hot_restart_0001.nc $RUNDIR/ham/output/ham_for_restart_0001.nc

# GOM forecast
cd $RUNDIR/ham/run
sed "s/__START_DATE__/${START_DATE}/g" ham_for_run.nml.template > ham_for_run.nml
sed -i "s/__END_DATE__/${END_DATE}/g" ham_for_run.nml
mpiexec -mca plm_rsh_agent "/opt/necofs/bin/vpc-ssh" -host $HOSTS -n $NPROCS /opt/necofs/bin/fvcom_ham --CASENAME=ham_for

# copy output to S3 bucket
aws s3 cp $RUNDIR/ham/output/ham_for_0001.nc s3://necofs/output/necofs_ham_${START}.nc
aws s3 cp $RUNDIR/ham/output/ham_for_restart_0001.nc s3://necofs/output/necofs_ham_restart_${START}.nc

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
START_DATE=`date -d "${START}" "+%Y-%m-%d_%H:%M:%S"`
END_DATE=`date -d "${END}" "+%Y-%m-%d_%H:%M:%S"`

# download $RUN_HOURS of NAM 221 AWIPS Grid - High Resolution North American Master Grid (32-km Resolution)
cd $RUNDIR/wrf
for h in $(seq 0 3 $RUN_HOURS); do
    hh=`printf %02d $h`
    echo "nam.t00z.awip32$hh.tm00.grib2"
    curl -s -O "ftp://ftp.ncep.noaa.gov/pub/data/nccf/com/nam/prod/nam.${START//-/}/nam.t00z.awip32$hh.tm00.grib2"
done

# WPS
cd $RUNDIR/wrf/wps
link_grib.csh ../nam.t00z*
sed "s/__START_DATE__/${START_DATE}/g" namelist.wps.template > namelist.wps
sed -i "s/__END_DATE__/${END_DATE}/g" namelist.wps
ungrib.exe

#mpiexec -host $HOSTS -n $NPROCS metgrid.exe
mpiexec -mca plm_rsh_agent "/opt/necofs/bin/vpc-ssh" -host $HOSTS -n $NPROCS /opt/necofs/bin/metgrid.exe

# WRF
cd $RUNDIR/wrf/wrf
ln -s ../wps/met_em* .
sed "s/__RUN_HOURS__/${RUN_HOURS}/g" namelist.input.template > namelist.input
sed -i "s/__START_Y__/${START_DATE:0:4}/g" namelist.input
sed -i "s/__START_M__/${START_DATE:5:2}/g" namelist.input
sed -i "s/__START_D__/${START_DATE:8:2}/g" namelist.input
sed -i "s/__START_H__/0/g" namelist.input
sed -i "s/__END_Y__/${END_DATE:0:4}/g" namelist.input
sed -i "s/__END_M__/${END_DATE:5:2}/g" namelist.input
sed -i "s/__END_D__/${END_DATE:8:2}/g" namelist.input
sed -i "s/__END_H__/${END_DATE:11:2}/g" namelist.input
mpiexec -mca plm_rsh_agent "/opt/necofs/bin/vpc-ssh" -host $HOSTS -n $NPROCS /opt/necofs/bin/real.exe
mpiexec -mca plm_rsh_agent "/opt/necofs/bin/vpc-ssh" -host $HOSTS -n $NPROCS /opt/necofs/bin/wrf.exe

cd $RUNDIR/wrf
wrf_to_fvcom_26z -forecast -i wrf/wrfout_d01_${START_DATE} -o wrf_for.nc

# copy results to S3 bucket
aws s3 cp wrf_for.nc s3://necofs/output/necofs_met_${START}.nc

# cleanup (optional if machine being terminated anyway)
rm -f wrf/met_em.d0*
rm -f wrf/rsl.*
rm -f wrf/namelist.input
rm -f wrf/namelist.output
rm -f wrf/wrfinput_d01
rm -f wrf/wrfbdy_d01
rm -f wrf/wrfout_d0*
rm -f wrf/wrfrst_d0*
rm -f wps/met_em*
rm -f wps/FILE*
rm -f wps/namelist.wps
rm -f wps/ungrib.log
rm -f wps/metgrid.log*
rm -f wps/GRIBFILE.*
rm -f nam.t00z*

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

cd $RUNDIR/wave

# =============
# Wavewatch III
# =============
# -- download $RUN_HOURS of NAM 221 AWIPS Grid - High Resolution North American Master Grid (32-km Resolution)
for h in $(seq 0 3 $RUN_HOURS); do
    hh=`printf %02d $h`
    echo "nam.t00z.awip32$hh.tm00.grib2"
    curl -s -O "ftp://ftp.ncep.noaa.gov/pub/data/nccf/com/nam/prod/nam.${START//-/}/nam.t00z.awip32$hh.tm00.grib2"
    # -- convert grib2 to netcdf file
    wgrib2 -match 'GRD:10 m above ground' -netcdf nam00$hh.nc nam.t00z.awip32$hh.tm00.grib2
    rm -f nam.t00z.awip32$hh.tm00.grib2
done

echo Finished--1 convert `date`

#==========================================================
#2. intepolate eta_wind to ww3 grid
#==========================================================
echo Begin-----2 ww3_nam_xbilin `date`
ww3_nam_xbilin
echo Finished--2 ww3_nam_xbilin `date`

#==========================================================
#3. write ww3/ww3_shel.inp file whith date
#==========================================================
echo Begin-----3 ww3_make_pre_inp `date`
ww3_make_pre_inp
echo Finished--3 ww3_make_pre_inp `date`

#==========================================================
#4. ww3
#==========================================================
cd $RUNDIR/wave/ww3
echo Begin-----4 ww3_grid `date`
ww3_grid
echo Finished--4 ww3_grid `date`
echo Begin-----5 ww3_strt `date`
ww3_strt
echo Finished--5 ww3_strt `date`
echo Begin-----6 ww3_prep `date`
ww3_prep
echo Finished--6 ww3_prep `date`
echo Begin-----7 ww3_shel `date`
#mpiexec -kill ww3_shel # TODO compile ww3_shel with MPI
ww3_shel
echo Finished--7 ww3_shel `date`

cd $RUNDIR/wave
cp $RUNDIR/wave/ww3/out_grd.ww3 $RUNDIR/wave/ww3/out
cp $RUNDIR/wave/ww3/mod_def.ww3 $RUNDIR/wave/ww3/out 

# TODO: make the path an arg to ww3_make_out_inp
#===========================================================
#5. write shell input file with date
#===========================================================
echo Begin-----9 ww3_make_out_inp `date`
ww3_make_out_inp
echo Finished--9 ww3_make_out_inp `date`

#===========================================================
#6. read out_grd.ww3 file and write hs,dir,fp,t,dp         #
#===========================================================
cd $RUNDIR/wave/ww3/out
echo Begin-----10 ww3_outf `date`
ww3_outf
echo Finished--10 ww3_outf `date`


# -- wait for WRF to be finished to proceed
while [ ! -f $RUNDIR/wrf/wrf_for.nc ]
do
  sleep 30
done

#================================================
# FVCOM GOM3 wave simulation
#================================================
cd $RUNDIR/wave/fvcom/run_gom3
# hotstart namelist
sed "s/__START_DATE__/${START_DATE}/g" gom_hot_run.nml.template > gom_hot_run.nml
sed -i "s/__START_DATE_PLUS_ONE_HOUR__/${START_DATE_PLUS_ONE_HOUR}/g" gom_hot_run.nml
# forecast namelist
sed "s/__START_DATE__/${START_DATE}/g" gom_for_run.nml.template > gom_for_run.nml
sed -i "s/__END_DATE__/${END_DATE}/g" gom_for_run.nml


#===========================================================
#7. interpolate wrf wind to gom3_wave grid
#===========================================================
cd $RUNDIR/wave/fvcom
echo Begin-----8 fvcom_wave_wrf_xbilin `date`
# -- interpolate WRF winds
fvcom_wave_wrf_xbilin
echo Finished--8 fvcom_wave_wrf_xbilin `date`

#===========================================================
#8. write input information and open boundary nest for wave_gom3 #
#===========================================================
echo Begin-----12 ./get_nest_bc `date`
ln -s $RUNDIR/wave/ww3/out/ww3.* .
fvcom_wave_get_nest_bc
rm -f ww3.*
echo Finished--12 ./get_nest_bc `date`

#===========================================================
#8. running wave_gom3 
#===========================================================
# download FVCOM restart file
cd $RUNDIR/wave/fvcom/input
curl -s -o gom_restart.nc "http://54.86.86.177/thredds/fileServer/RESTART/WAVE/Files/${START//-/}00.nc"

# GOM hotstart
cd $RUNDIR/wave/fvcom/run_gom3
mpiexec -mca plm_rsh_agent "/opt/necofs/bin/vpc-ssh" -host $HOSTS -n $NPROCS /opt/necofs/bin/fvcom_wave --CASENAME=gom_hot

ln -s $RUNDIR/wave/fvcom/output/gom_hot_0001.nc $RUNDIR/wave/fvcom/output/gom_for_0001.nc
ln -s $RUNDIR/wave/fvcom/output/gom_hot_restart_0001.nc $RUNDIR/wave/fvcom/output/gom_for_restart_0001.nc

# GOM forecast
mpiexec -mca plm_rsh_agent "/opt/necofs/bin/vpc-ssh" -host $HOSTS -n $NPROCS /opt/necofs/bin/fvcom_wave --CASENAME=gom_for

# copy output to S3 bucket
aws s3 cp $RUNDIR/fvcom/wave/output/gom_for_0001.nc s3://necofs/output/necofs_wave_${START}.nc
aws s3 cp $RUNDIR/fvcom/wave/output/gom_for_restart_0001.nc s3://necofs/output/necofs_wave_restart_${START}.nc

# cleanup (optional if machine being terminated anyway)
cd $RUNDIR/wave
rm ww3/restart*.ww3
rm ww3/watlantic.inp
rm ww3/ww3_shel.inp
rm ww3/mod_def.ww3
rm ww3/mask.ww3
rm ww3/wind.ww3
rm ww3/test.ww3
rm ww3/out_grd.ww3
rm ww3/log.ww3 
rm ww3/out/*

from __future__ import print_function
import boto
import boto.ec2
import boto.utils
import copy
import jinja2
import json
import multiprocessing
import os
import subprocess
import sys
import time
import urllib2

# logging methods
def warning(*objs):
    print("WARNING: ", *objs, file=sys.stderr)
def info(*objs):
    print("INFO: ", *objs, file=sys.stdout)

def main():

    # -- configuration JSON file
    with open(sys.argv[1]) as f:    
        o = json.load(f)

    # -- create Amazon EC2 Volume and export NFS
    with open('/etc/exports', 'w') as f:
        create_volume(o['SNAPSHOT'], o['MOUNT'])
        print('%s *(rw)' % o['MOUNT'], file=f)
    subprocess.call(['exportfs', '-r'])

    # -- configure ENVIRONMENT variables for bash scripts (source NECOFS bashrc and copy ENV to Python dict)
    output = subprocess.check_output("source /opt/necofs/bashrc; env", shell=True)
    bash_env = dict(line.split("=",1) for line in output.splitlines() if "=" in line)
    bash_env['RUNDIR'] = "/opt/necofs/var/NECOFS" # this is the PATH expected on the AWS EC2 Volume (created via Snapshot)
    bash_env['RUN_HOURS'] = str(o['RUN_HOURS'])
    bash_env['START'] = o['START']
    #info(bash_env)

    # -- model execution wrappers (sets up environments and calls bash scripts)
    def wrf_gom_mbn(bash_env):
        info('[WRF/GOM/MBN] start')
        # -- configure Instances
        wrf_gom_mbn_reservations = []
        for wrf_gom_mbn_i in range(2): # 2 for WRF/GOM/MBN #hardcoded
            info("[WRF/GOM/MBN] create compute")
            wrf_gom_mbn_reservations.append(_create_compute(o,'WRF_GOM_MBN'))
        # -- get private IPs of the compute nodes
        wrf_gom_mbn_compute_instance_ids = []
        wrf_gom_mbn_compute_ips = []
        for wrf_gom_mbn_reservation in wrf_gom_mbn_reservations:
            wrf_gom_mbn_compute_instance_ids.extend([i.id for i in wrf_gom_mbn_reservation.instances])
            wrf_gom_mbn_compute_ips.extend([i.private_ip_address for i in wrf_gom_mbn_reservation.instances])
        info("[WRF/GOM/MBN] COMPUTE NODE IDS: %s" % ",".join(wrf_gom_mbn_compute_instance_ids))
        info("[WRF/GOM/MBN] COMPUTE NODE IPS: %s" % ",".join(wrf_gom_mbn_compute_ips))
        info("[WRF/GOM/MBN] waiting a bit for SSH to become available on COMPUTE nodes")
        time.sleep(180) # wait for the instances to come up (3 minutes should suffice)
        # set bash ENV
        wrf_gom_mbn_bash_env = copy.deepcopy(bash_env)
        wrf_gom_mbn_bash_env['HOSTS'] = ",".join(wrf_gom_mbn_compute_ips)
        wrf_gom_mbn_bash_env['NPROCS'] = str(72) #hardcoded (36*2)
        # -- run WRF
        with open("/tmp/run_wrf.log","wb") as out, open("/tmp/run_wrf.err","wb") as err:
            p = subprocess.Popen(['su', '-m', 'ec2-user', '-c', '/opt/necofs/var/NECOFS/wrf/run_wrf.sh'], env=wrf_gom_mbn_bash_env, stdout=out, stderr=err)
            p.wait()
        # -- run GOM
        with open("/tmp/run_gom.log","wb") as out, open("/tmp/run_gom.err","wb") as err:
            p = subprocess.Popen(['su', '-m', 'ec2-user', '-c', '/opt/necofs/var/NECOFS/gom/run_gom.sh'], env=wrf_gom_mbn_bash_env, stdout=out, stderr=err)
            p.wait()
        # -- run MBN
        with open("/tmp/run_mbn.log","wb") as out, open("/tmp/run_mbn.err","wb") as err:
            p = subprocess.Popen(['su', '-m', 'ec2-user', '-c', '/opt/necofs/var/NECOFS/mbn/run_mbn.sh'], env=wrf_gom_mbn_bash_env, stdout=out, stderr=err)
            p.wait()
        # terminate the compute nodes created for this group of runs
        terminate_compute(wrf_gom_mbn_compute_instance_ids)
        info('WRF/GOM/MBN stop')

    def wave(bash_env):
        info('[WAVE] start')
        # -- configure the Instances
        wave_reservations = []
        for wave_i in range(1): # 1 for WAVE #hardcoded
            info("[WAVE] create compute")
            wave_reservations.append(_create_compute(o,'WAVE'))
        # -- get private IPs of the compute nodes
        wave_compute_instance_ids = []
        wave_compute_ips = []
        for wave_reservation in wave_reservations:
            wave_compute_instance_ids.extend([i.id for i in wave_reservation.instances])
            wave_compute_ips.extend([i.private_ip_address for i in wave_reservation.instances])
        info("[WAVE] COMPUTE NODE IDS: %s" % ",".join(wave_compute_instance_ids))
        info("[WAVE] COMPUTE NODE IPS: %s" % ",".join(wave_compute_ips))
        info("[WAVE] waiting a bit for SSH to become available on COMPUTE nodes")
        time.sleep(180) # wait for the instances to come up (3 minutes should suffice)
        # set bash ENV
        wave_bash_env = copy.deepcopy(bash_env)
        wave_bash_env['HOSTS'] = ",".join(wave_compute_ips)
        wave_bash_env['NPROCS'] = str(18) #hardcoded (only physical procs for fastest PETSc)
        # -- run WAVE
        with open("/tmp/run_wave.log","wb") as out, open("/tmp/run_wave.err","wb") as err:
            p = subprocess.Popen(['su', '-m', 'ec2-user', '-c', '/opt/necofs/var/NECOFS/wave/run_wave.sh'], env=wave_bash_env, stdout=out, stderr=err)
            p.wait()
        # terminate the compute nodes created for this group of runs
        terminate_compute(wave_compute_instance_ids)
        info('[WAVE] stop')

    def ham(bash_env):
        info('[HAM] start')
        # -- configure the Instances
        ham_reservations = []
        for ham_i in range(1): # 1 for HAM #hardcoded
            info("[HAM] create compute")
            ham_reservations.append(_create_compute(o,'HAM'))
        # -- get private IPs of the compute nodes
        ham_compute_instance_ids = []
        ham_compute_ips = []
        for ham_reservation in ham_reservations:
            ham_compute_instance_ids.extend([i.id for i in ham_reservation.instances])
            ham_compute_ips.extend([i.private_ip_address for i in ham_reservation.instances])
        info("[HAM] COMPUTE NODE IDS: %s" % ",".join(ham_compute_instance_ids))
        info("[HAM] COMPUTE NODE IPS: %s" % ",".join(ham_compute_ips))
        info("[HAM] waiting a bit for SSH to become available on COMPUTE nodes")
        time.sleep(180) # wait for the instances to come up (3 minutes should suffice)
        # set bash ENV
        ham_bash_env = copy.deepcopy(bash_env)
        ham_bash_env['HOSTS'] = ",".join(ham_compute_ips)
        ham_bash_env['NPROCS'] = str(18) #hardcoded (only physical procs for fastest PETSc)
        # -- run HAM
        with open("/tmp/run_ham.log","wb") as out, open("/tmp/run_ham.err","wb") as err:
            p = subprocess.Popen(['su', '-m', 'ec2-user', '-c', '/opt/necofs/var/NECOFS/ham/run_ham.sh'], env=ham_bash_env, stdout=out, stderr=err)
            p.wait()
        # terminate the compute nodes created for this group of runs
        terminate_compute(ham_compute_instance_ids)
        info('[HAM] stop')

    def sci(bash_env):
        info('[SCI] start')
        # -- configure the Instances
        sci_reservations = []
        for sci_i in range(1): # 1 for SCI #hardcoded
            info("[SCI] create compute")
            sci_reservations.append(_create_compute(o,'SCI'))
        # -- get private IPs of the compute nodes
        sci_compute_instance_ids = []
        sci_compute_ips = []
        for sci_reservation in sci_reservations:
            sci_compute_instance_ids.extend([i.id for i in sci_reservation.instances])
            sci_compute_ips.extend([i.private_ip_address for i in sci_reservation.instances])
        info("[SCI] COMPUTE NODE IDS: %s" % ",".join(sci_compute_instance_ids))
        info("[SCI] COMPUTE NODE IPS: %s" % ",".join(sci_compute_ips))
        info("[SCI] waiting a bit for SSH to become available on COMPUTE nodes")
        time.sleep(180) # wait for the instances to come up (3 minutes should suffice)
        # set bash ENV
        sci_bash_env = copy.deepcopy(bash_env)
        sci_bash_env['HOSTS'] = ",".join(sci_compute_ips)
        sci_bash_env['NPROCS'] = str(18) #hardcoded (only physical procs for fastest PETSc)
        # -- run SCI
        with open("/tmp/run_sci.log","wb") as out, open("/tmp/run_sci.err","wb") as err:
            p = subprocess.Popen(['su', '-m', 'ec2-user', '-c', '/opt/necofs/var/NECOFS/sci/run_sci.sh'], env=sci_bash_env, stdout=out, stderr=err)
            p.wait()
        # terminate the compute nodes created for this group of runs
        terminate_compute(sci_compute_instance_ids)
        info('[SCI] stop')

    # execute models
    info('[MASTER] running WRF/GOM/MBN')
    p_wrf_gom_mbn = multiprocessing.Process(target=wrf_gom_mbn, args=(bash_env,))
    p_wrf_gom_mbn.start()

    info('[MASTER] running WAVE model')
    p_wave = multiprocessing.Process(target=wave, args=(bash_env,))
    p_wave.start()

    info('[MASTER] waiting for WAVE model to finish')
    p_wave.join() # block and wait

    info('[MASTER] running HAM model')
    p_ham = multiprocessing.Process(target=ham, args=(bash_env,))
    p_ham.start()

    info('[MASTER] running SCI')
    p_sci = multiprocessing.Process(target=sci, args=(bash_env,))
    p_sci.start()

    info('[MASTER] waiting for models to finish')
    p_wrf_gom_mbn.join() # block and wait
    p_ham.join() # block and wait
    p_sci.join # block and wait

# =======
# methods
# =======
def _get_available_device_name():
    for l in list(map(chr, range(102, 123))):
        device = "xvd%s" % l
        path = "/dev/%s" % device
        try:
            os.stat(path)
        except OSError:
            return path

def create_volume(snapshot_id, mount_point):
    for snapshot in ec2.get_all_snapshots(snapshot_ids=[snapshot_id]):
        volume = snapshot.create_volume(availability_zone,volume_type='gp2')
        while volume.volume_state() != 'available':
            time.sleep(1)
            volume.update()
        device_name = _get_available_device_name()
        ec2.attach_volume(volume.id, instance_id, device_name)
        while volume.attachment_state() != 'attached':
            time.sleep(1)
            volume.update()
        try:
            os.makedirs(mount_point)
        except:
            pass
        status = subprocess.call(['mount', device_name, mount_point])
        return volume

def destroy_volume(mount_point, volume):
    # mount volume TODO check was unmounted
    status = subprocess.call(['umount', mount_point])
    # detach volume
    ec2.detach_volume(volume.id)
    # wait until volume's attachment state is 'None'
    while volume.attachment_state() is not None:
        time.sleep(1)
        volume.update()
    # delete volume
    ec2.delete_volume(volume.id)

def _create_compute(config, name):
    info("[CREATE COMPUTE] "+name)
    # user_data from template
    j2_env = jinja2.Environment(loader=jinja2.FileSystemLoader('/opt/necofs/templates'))
    USER_DATA = j2_env.get_template('compute.user_data').render(local_ipv4=local_ipv4)
    # create a NetworkInterface in our VPC
    interface = boto.ec2.networkinterface.NetworkInterfaceSpecification(
        subnet_id                   = config['SUBNET_ID'],
        groups                      = config['SECURITY_GROUP_IDS'],
        associate_public_ip_address = True
    )
    interfaces = boto.ec2.networkinterface.NetworkInterfaceCollection(interface)
    reservation = ec2.run_instances(
        image_id = config['IMAGE_ID'],
        key_name = config['KEY_NAME'],
        user_data = USER_DATA,
        instance_type = config['COMPUTE_INSTANCE_TYPE'],
        instance_initiated_shutdown_behavior = 'terminate',
        placement_group = config['PLACEMENT_GROUP'], # only for high level machines, not for testing
        network_interfaces = interfaces,
        instance_profile_name = config['IAM_ROLE']
    )
    info("[CREATE_COMPUTE]: reservation "+reservation.id+" for "+name)
    time.sleep(30) # -- was checking before instance was created, wait a few for Amazon to notice it's own machine
    for instance in reservation.instances:
        status = instance.update()
        while status == 'pending':
            time.sleep(5)
            status = instance.update()
        instance.add_tag('Name', config['INSTANCE_NAME']+"_compute_"+name)
    return reservation

def terminate_compute(instance_ids):
    ec2.terminate_instances(instance_ids)
    
# EC2 Instance Metadata
instance_metadata = boto.utils.get_instance_metadata()
instance_id       = instance_metadata.get('instance-id')
placement         = instance_metadata.get('placement')
availability_zone = placement.get('availability-zone')
region            = availability_zone[:-1]
ec2               = boto.ec2.connect_to_region(region)
s3                = boto.connect_s3()
local_ipv4        = instance_metadata.get('local-ipv4')

if __name__ == "__main__":
    main()

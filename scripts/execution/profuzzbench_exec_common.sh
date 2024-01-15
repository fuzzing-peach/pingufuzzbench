#!/bin/bash

DOCIMAGE=$1   #name of the docker image
RUNS=$2       #number of runs
SAVETO=$3     #path to folder keeping the results

FUZZER=$4     #fuzzer name (e.g., aflnet) -- this name must match the name of the fuzzer folder inside the Docker container
OUTDIR=$5     #name of the output folder created inside the docker container
OPTIONS=$6    #all configured options for fuzzing
TIMEOUT=$7    #time for fuzzing
SKIPCOUNT=$8  #used for calculating coverage over time. e.g., SKIPCOUNT=5 means we run gcovr after every 5 test cases
DELETE=$9

WORKDIR="/home/ubuntu/experiments"

# CPU分配文件
CPU_ALLOCATION_FILE="cpu_allocation"

# 初始化CPU分配文件
initialize_cpu_allocation() {
    if [ ! -f $CPU_ALLOCATION_FILE ]; then
        # 获取系统CPU数量
        local cpu_count=$(nproc)
        local cpus=$(seq 0 $((cpu_count - 1)) | paste -sd ',' -)
        echo $cpus > $CPU_ALLOCATION_FILE
    fi
}

# 获取一个未分配的CPU
available_cpu() {
    local available_cpus=$(cat $CPU_ALLOCATION_FILE)
    IFS=',' read -ra cpus <<< "$available_cpus"
    for cpu in "${cpus[@]}"; do
        if [ ! -z "$cpu" ]; then
            echo $cpu
            return
        fi
    done
}

# 分配CPU
allocate_cpu() {
    local cpu=$1
    local cpus=$(cat $CPU_ALLOCATION_FILE)
    # 在CPU编号前后添加逗号，以确保精确匹配
    cpus=",$cpus,"
    cpus=${cpus//,$cpu,/}
    
    # 处理字符串两端的逗号
    cpus=${cpus#,}
    cpus=${cpus%,}
    echo $cpus > $CPU_ALLOCATION_FILE
}

# 释放CPU
release_cpu() {
    local cpu_to_add=$1
    local cpus=$(cat $CPU_ALLOCATION_FILE)
    cpus="${cpus},${cpu_to_add}"
    cpus=${cpus//,,/,}
    cpus=${cpus#,}
    echo $cpus > $CPU_ALLOCATION_FILE
}

#keep all container ids
cids=()

initialize_cpu_allocation

#create one container for each run
for i in $(seq 1 $RUNS); do
  cpu=$(available_cpu)
  allocate_cpu $cpu
  container_name="$DOCIMAGE-$FUZZER-$i-$cpu"
  id=$(docker run --name $container_name --cpuset-cpus="$cpu" -d -it $DOCIMAGE /bin/bash -c "cd ${WORKDIR} && run ${FUZZER} ${OUTDIR} '${OPTIONS}' ${TIMEOUT} ${SKIPCOUNT}")
  cids+=(${id::12}) #store only the first 12 characters of a container ID
done

dlist="" #docker list
for id in ${cids[@]}; do
  dlist+=" ${id}"
done

#wait until all these dockers are stopped
printf "\n${FUZZER^^}: Fuzzing in progress ..."
printf "\n${FUZZER^^}: Waiting for the following containers to stop: ${dlist}"
docker wait ${dlist} > /dev/null
wait

#collect the fuzzing results from the containers
printf "\n${FUZZER^^}: Collecting results and save them to ${SAVETO}"
index=1
for id in ${cids[@]}; do
  printf "\n${FUZZER^^}: Collecting results from container ${id}"
  docker cp ${id}:/home/ubuntu/experiments/${OUTDIR}.tar.gz ${SAVETO}/${OUTDIR}_${index}.tar.gz > /dev/null
  if [ ! -z $DELETE ]; then
    container_name=$(docker inspect --format '{{.Name}}' $id | sed 's/^\/\([^ ]*\).*$/\1/')
    cpu="${container_name##*-}"
    printf "\nDeleting ${id} and releasing cpu#${cpu}"
    release_cpu $cpu
    docker rm ${id} # Remove container now that we don't need it
  fi
  index=$((index+1))
done

printf "\n${FUZZER^^}: I am done!\n"

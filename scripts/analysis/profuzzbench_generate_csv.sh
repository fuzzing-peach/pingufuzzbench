#!/bin/bash
prog=$1        #name of the subject program (e.g., lightftp)
runs=$2        #total number of runs
fuzzers=$3     #fuzzer name (e.g., aflnet) -- this name must match the name of the fuzzer folder inside the Docker container
covfile=$4     #output CSV file
execfile=$5
append=$6      #append mode
               #enable this mode when the results of different fuzzers need to be merged

#create a new file if append = 0
if [ $append = "0" ]; then
  rm $covfile; touch $covfile
  echo "time,subject,fuzzer,run,cov_type,cov" >> $covfile

  rm $execfile; touch $execfile
  echo "time,subject,fuzzer,run,paths,objectives,edges,executions" >> $execfile
fi

# remove space(s) 
trim() {
    local var="$1"
    # 删除开头的空格
    var="${var#"${var%%[![:space:]]*}"}"
    # 删除结尾的空格
    var="${var%"${var##*[![:space:]]}"}"
    echo "$var"
}

# original format: time,l_per,l_abs,b_per,b_abs
# converted format: time,subject,fuzzer,run,cov_type,cov
convert() {
  fuzzer=$1
  subject=$2
  run_index=$3
  ifile=$4
  ofile=$5

  {
    read #ignore the header
    while read -r line; do
      time=$(trim $(echo $line | cut -d',' -f1))
      l_per=$(trim $(echo $line | cut -d',' -f2))
      l_abs=$(trim $(echo $line | cut -d',' -f3))
      b_per=$(trim $(echo $line | cut -d',' -f4))
      b_abs=$(trim $(echo $line | cut -d',' -f5))
      echo $time,$subject,$fuzzer,$run_index,"l_per",$l_per >> $ofile
      echo $time,$subject,$fuzzer,$run_index,"l_abs",$l_abs >> $ofile
      echo $time,$subject,$fuzzer,$run_index,"b_per",$b_per >> $ofile
      echo $time,$subject,$fuzzer,$run_index,"b_abs",$b_abs >> $ofile
    done 
  } < $ifile
}

convert_plot_data() {
  fuzzer=$1
  subject=$2
  run_index=$3
  ifile=$4
  ofile=$5

  
  {
    read #ignore the header
    while read -r line; do
      time=$(trim $(echo $line | cut -d',' -f1))
      if [[ $fuzzer = "libaflnet" ]]; then
        paths=$(trim $(echo $line | cut -d',' -f2))
        objectives=$(trim $(echo $line | cut -d',' -f3))
        edges=$(trim $(echo $line | cut -d',' -f4))
        executions=$(trim $(echo $line | cut -d',' -f5))
      else
        paths=$(trim $(echo $line | cut -d',' -f4))
        crashes=$(trim $(echo $line | cut -d',' -f8))
        hangs=$(trim $(echo $line | cut -d',' -f9))
        objectives=$((crashes + hangs))
        edges=$(trim $(echo $line | cut -d',' -f7))
        executions=$(trim $(echo $line | cut -d',' -f11))
      fi
      echo $time,$subject,$fuzzer,$run_index,$paths,$objectives,$edges,$executions >> $ofile
    done 
  } < $ifile
}

if [ $fuzzers = "libaflnet" ]; then
  plot_data_name="stats.csv"
else
  plot_data_name="plot_data"
fi

#extract tar files & process the data
for fuzzer in $fuzzers; do 
  for i in $(seq 1 $runs); do 
    printf "\nProcessing out-${prog}-${fuzzer}-${i} ..."
    rm -rf out-${prog}-${fuzzer}-${i}
    #tar -zxvf out-${prog}-${fuzzer}_${i}.tar.gz > /dev/null 2>&1
    tar -axf out-${prog}-${fuzzer}_${i}.tar.gz out-${prog}-${fuzzer}/cov_over_time.csv
    tar -axf out-${prog}-${fuzzer}_${i}.tar.gz out-${prog}-${fuzzer}/$plot_data_name
    mv out-${prog}-${fuzzer} out-${prog}-${fuzzer}-${i}
    #combine all csv files
    convert $fuzzer $prog $i out-${prog}-${fuzzer}-${i}/cov_over_time.csv $covfile
    convert_plot_data $fuzzer $prog $i out-${prog}-${fuzzer}-${i}/$plot_data_name $execfile
  done 
done

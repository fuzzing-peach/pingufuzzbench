#!/bin/bash
prog=$1    #name of the subject program (e.g., lightftp)
runs=$2    #total number of runs
fuzzers=$3 #fuzzer name (e.g., aflnet) -- this name must match the name of the fuzzer folder inside the Docker container
covfile=$4 #output CSV file
append=$5  #append mode
#enable this mode when the results of different fuzzers need to be merged

#create a new file if append = 0
if [ $append = "0" ]; then
  rm $covfile
  touch $covfile
  echo "time,subject,fuzzer,run,cov_type,cov" >>$covfile
fi

#remove space(s)
#it requires that there is no space in the middle
strim() {
  trimmedStr=$1
  echo "${trimmedStr##*( )}"
}

#original format: time,l_per,l_abs,b_per,b_abs
#converted format: time,subject,fuzzer,run,cov_type,cov
convert() {
  fuzzer=$1
  subject=$2
  run_index=$3
  ifile=$4
  ofile=$5

  {
    read #ignore the header
    while read -r line; do
      time=$(strim $(echo $line | cut -d',' -f1))
      l_per=$(strim $(echo $line | cut -d',' -f2))
      l_abs=$(strim $(echo $line | cut -d',' -f3))
      b_per=$(strim $(echo $line | cut -d',' -f4))
      b_abs=$(strim $(echo $line | cut -d',' -f5))
      echo $time,$subject,$fuzzer,$run_index,"l_per",$l_per >>$ofile
      echo $time,$subject,$fuzzer,$run_index,"l_abs",$l_abs >>$ofile
      echo $time,$subject,$fuzzer,$run_index,"b_per",$b_per >>$ofile
      echo $time,$subject,$fuzzer,$run_index,"b_abs",$b_abs >>$ofile
    done
  } <$ifile
}



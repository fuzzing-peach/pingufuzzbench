#!/bin/bash

fuzzer=$1   #fuzzer name
folder=$2   #fuzzer result folder
pno=$3      #port number
step=$4     #step to skip running gcovr and outputting data to covfile
            #e.g., step=5 means we run gcovr after every 5 test cases
covfile=$5  #path to coverage file

#delete the existing coverage file
rm $covfile; touch $covfile

#clear gcov data
gcovr -r . -s -d > /dev/null 2>&1

#output the header of the coverage file which is in the CSV format
#Time: timestamp, l_per/b_per and l_abs/b_abs: line/branch coverage in percentage and absolutate number
echo "Time,l_per,l_abs,b_per,b_abs" >> $covfile

# files stored in replayable-* folders are structured
# in such a way that messages are separated
if [ $fuzzer = "aflnet" ]; then
  # aflnet
  replayer="aflnet-replay"
  testcases=$(echo $folder/replayable-queue/id*)
elif [ $fuzzer = "aflnwe" ]; then
  # aflnwe
  replayer="afl-replay"
  testcases=$(echo $folder/queue/id*)
else
  # libaflnet
  replayer="/home/ubuntu/libaflnet/aflnet-replay"
  testcases=$(find $folder/queue -type f -name '*trace' | while read -r file; do
    number=$(echo "$file" | grep -oE 'ts:[0-9]+' | grep -oE '[0-9]+' | head -n 1)
    if [[ -n $number ]]; then
        echo "$number $file"
    fi
    done | sort -n | cut -d ' ' -f2-)
fi

#process initial seed corpus first
count=0
for f in $testcases; do
  if [ $fuzzer = "libaflnet" ]; then
    time=$(echo $f | grep -oE 'ts:[0-9]+' | grep -oE '[0-9]+' | head -n 1)
  else
    time=$(stat -c %Y $f)
  fi

  #terminate running server(s)
  pkill pure-ftpd

  if [ $fuzzer = "libaflnet" ]; then
    p="ftp"
  else
    p="FTP"
  fi

  $replayer $f $p $pno 1 > /dev/null 2>&1 &
  GCOV_PREFIX=/home/fuzzing/ timeout -k 0 3s src/pure-ftpd -A
  
  wait
  count=$(expr $count + 1)
  rem=$(expr $count % $step)
  if [ "$rem" != "0" ]; then continue; fi
  cp /home/fuzzing/home/ubuntu/experiments/pure-ftpd-gcov/src/*.gcda /home/ubuntu/experiments/pure-ftpd-gcov/src/ > /dev/null 2>&1
  cov_data=$(gcovr -r . -s | grep "[lb][a-z]*:")
  echo $cov_data
  l_per=$(echo "$cov_data" | grep lines | cut -d" " -f2 | rev | cut -c2- | rev)
  l_abs=$(echo "$cov_data" | grep lines | cut -d" " -f3 | cut -c2-)
  b_per=$(echo "$cov_data" | grep branch | cut -d" " -f2 | rev | cut -c2- | rev)
  b_abs=$(echo "$cov_data" | grep branch | cut -d" " -f3 | cut -c2-)
  
  echo "$time,$l_per,$l_abs,$b_per,$b_abs" >> $covfile
done

#ouput cov data for the last testcase(s) if step > 1
if [[ $step -gt 1 ]]
then
  time=$(stat -c %Y $f)
  cov_data=$(gcovr -r . -s | grep "[lb][a-z]*:")
  l_per=$(echo "$cov_data" | grep lines | cut -d" " -f2 | rev | cut -c2- | rev)
  l_abs=$(echo "$cov_data" | grep lines | cut -d" " -f3 | cut -c2-)
  b_per=$(echo "$cov_data" | grep branch | cut -d" " -f2 | rev | cut -c2- | rev)
  b_abs=$(echo "$cov_data" | grep branch | cut -d" " -f3 | cut -c2-)
  
  echo "$time,$l_per,$l_abs,$b_per,$b_abs" >> $covfile
fi

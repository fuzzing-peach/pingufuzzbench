#!/bin/bash

fuzzer=$1   #fuzzer name
folder=$2   #fuzzer result folder
pno=$3      #port number
step=$4     #step to skip running gcovr and outputting data to covfile
            #e.g., step=5 means we run gcovr after every 5 test cases
covfile=$5  #path to coverage file

# delete the existing coverage file
rm $covfile; touch $covfile

# clear gcov data
# since the source files of LightFTP are stored in the parent folder of the current folder
# we use '..' instead of '.' as usual. You may need to update this accordingly for your subject
gcovr -r .. -s -d > /dev/null 2>&1

# output the header of the coverage file which is in the CSV format
# Time: timestamp, l_per/b_per and l_abs/b_abs: line/branch coverage in percentage and absolutate number
echo "Time,l_per,l_abs,b_per,b_abs" >> $covfile

# clear ftp data
# this is a LightFTP-specific step
# we need to clean the ftp shared folder to prevent underterministic behaviors.
ftpclean

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

# process fuzzer-generated testcases
count=0
for f in $testcases; do
  if [ $fuzzer = "libaflnet" ]; then
    time=$(echo $f | grep -oE 'ts:[0-9]+' | grep -oE '[0-9]+' | head -n 1)
  else
    time=$(stat -c %Y $f)
  fi

  # terminate running server(s)
  pkill fftp
  
  ftpclean
  if [ $fuzzer = "libaflnet" ]; then
    p="ftp"
  else
    p="FTP"
  fi  
  $replayer $f $p $pno > /dev/null 2>&1 &
  timeout -k 0 -s SIGUSR1 3s ./fftp fftp.conf $pno > /dev/null 2>&1

  wait
  count=$(expr $count + 1)
  rem=$(expr $count % $step)
  if [ "$rem" != "0" ]; then continue; fi
  cov_data=$(gcovr -r .. -s | grep "[lb][a-z]*:")
  echo $f $cov_data
  l_per=$(echo "$cov_data" | grep lines | cut -d" " -f2 | rev | cut -c2- | rev)
  l_abs=$(echo "$cov_data" | grep lines | cut -d" " -f3 | cut -c2-)
  b_per=$(echo "$cov_data" | grep branch | cut -d" " -f2 | rev | cut -c2- | rev)
  b_abs=$(echo "$cov_data" | grep branch | cut -d" " -f3 | cut -c2-)
  
  echo "$time,$l_per,$l_abs,$b_per,$b_abs" >> $covfile
done

# ouput cov data for the last testcase(s) if step > 1
if [[ $step -gt 1 ]]
then
  time=$(stat -c %Y $f)
  cov_data=$(gcovr -r .. -s | grep "[lb][a-z]*:")
  l_per=$(echo "$cov_data" | grep lines | cut -d" " -f2 | rev | cut -c2- | rev)
  l_abs=$(echo "$cov_data" | grep lines | cut -d" " -f3 | cut -c2-)
  b_per=$(echo "$cov_data" | grep branch | cut -d" " -f2 | rev | cut -c2- | rev)
  b_abs=$(echo "$cov_data" | grep branch | cut -d" " -f3 | cut -c2-)
  
  echo "$time,$l_per,$l_abs,$b_per,$b_abs" >> $covfile
fi

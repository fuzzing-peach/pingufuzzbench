Please carefully read the [main README.md](../../../README.md), which is stored in the benchmark's root folder, before following this subject-specific guideline.

# Fuzzing ProFTPD server with AFLNet and AFLnwe
Please follow the steps below to run and collect experimental results for ProFTPD, which is a popular File Transfer Protocol (FTP) server.

## Step-1. Build a docker image
The following commands create a docker image tagged ProFTPD. The image should have everything available for fuzzing and code coverage calculation.

```bash
cd $PFBENCH
cd subjects/FTP/ProFTPD
docker build . -t proftpd
```

## Step-2. Run fuzzing
The following commands run 4 instances of AFLNet and 4 instances of AFLnwe to simultaenously fuzz ProFTPD in 60 minutes.

```bash
cd $PFBENCH
mkdir results-proftpd

profuzzbench_exec_common.sh proftpd 10 results-proftpd aflnet out-proftpd-aflnet "-t 1000+ -P FTP -D 10000 -q 3 -s 3 -E -K" 86400 5 1 &
profuzzbench_exec_common.sh proftpd 10 results-proftpd aflnwe out-proftpd-aflnwe "-t 1000+ -D 10000 -K" 86400 5 1 &
profuzzbench_exec_common.sh proftpd 10 results-proftpd libaflnet out-proftpd-libaflnet "-P ftp" 86400 5 1 &
```

## Step-3. Collect the results
The following commands collect the  code coverage results produced by AFLNet and AFLnwe and save them to results.csv.

```bash
cd $PFBENCH/results-proftpd

profuzzbench_generate_csv.sh proftpd 10 aflnet results_cov.csv results_exec.csv 0 && \
profuzzbench_generate_csv.sh proftpd 10 aflnwe results_cov.csv results_exec.csv 1 && \
profuzzbench_generate_csv.sh proftpd 10 libaflnet results_cov.csv results_exec.csv 1
```

## Step-4. Analyze the results
The results collected in step 3 (i.e., results.csv) can be used for plotting. Use the following command to plot the coverage over time and save it to a file.

```bash
cd $PFBENCH/results-proftpd

profuzzbench_plot.py -t cov -i results_cov.csv -p proftpd -r 4 -c 60 -s 1 -o cov_over_time.jpg && \
profuzzbench_plot.py -t exec -i results_exec.csv -p proftpd -r 4 -c 60 -s 1 -o exec_over_time.jpg
```

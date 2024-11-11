#!/usr/bin/env python3

import argparse
import pandas as pd
from pandas import read_csv
from pandas import DataFrame
import matplotlib.pyplot as plt

def plot_coverage(coverage_files, cut_off, step, out_file):
    # Initialize an empty list to hold dataframes
    df_list = []
    
    if not step:
        step = 1
        
    if not cut_off:
        cut_off = 60
        
    if not out_file:
        out_file = "coverage.jpg"
    
    # Loop through each coverage file
    for i, file in enumerate(coverage_files):
        # Read the CSV file into a DataFrame
        df = pd.read_csv(file)
        
        # Convert the 'time' column to datetime, where time is in seconds
        df['time'] = pd.to_datetime(df['time'], unit='s')
        
        # Truncate the 'time' column to the minute
        df['time'] = df['time'].dt.floor('min')
        df = df.groupby(by='time').apply(lambda d: d.iloc[-1], include_groups=False).reset_index()
        start_time = df['time'].iloc[0]
        end_time = start_time + pd.Timedelta(minutes=cut_off * step)
        time_range = pd.date_range(start=start_time, end=end_time, freq='min')
        df = df.set_index('time').reindex(time_range).ffill().reset_index(names="time")
        df['time'] = (df['time'] - start_time).dt.total_seconds() / 60
        df['time'] = df['time'].astype(int)
        df['run'] = i + 1
        df['run'] = df['run'].astype(int)
        df_list.append(df)

    # Concatenate all DataFrames in the list into a single DataFrame
    combined_df = pd.concat(df_list, ignore_index=True)
    
    # 2 x 2 subplots
    fig, axs = plt.subplots(2, 2, figsize=(20, 10))
    # The first row is for the lines coverage (l_abs, l_per)
    # The second row is for the branches coverage (b_abs, b_per)
    plot_coverage_subgraph(combined_df[['time', 'l_abs']], axs[0, 0], 'Lines Coverage (Count)', 'Lines Coverage Count')
    plot_coverage_subgraph(combined_df[['time', 'l_per']], axs[0, 1], 'Lines Coverage (%)', 'Lines Coverage Ratio')
    plot_coverage_subgraph(combined_df[['time', 'b_abs']], axs[1, 0], 'Branches Coverage (Count)', 'Branches Coverage Count')
    plot_coverage_subgraph(combined_df[['time', 'b_per']], axs[1, 1], 'Branches Coverage (%)', 'Branches Coverage Ratio')
    
    plt.savefig(out_file)
    
def plot_coverage_subgraph(df, ax, y_label, title):
    df = df.reset_index(drop=True)
    min_coverage = df.groupby('time').min().squeeze()
    max_coverage = df.groupby('time').max().squeeze()
    mean_coverage = df.groupby('time').mean().squeeze()
    times = df['time'].drop_duplicates().sort_values()
    ax.fill_between(times, min_coverage, max_coverage, color='lightblue')
    ax.plot(times, mean_coverage, color='blue')
    ax.set_xlabel('Time (min)')
    ax.set_ylabel(y_label)
    ax.set_title(title)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument("coverage_files", nargs='+', help="Coverage files")
    parser.add_argument('-c','--cut_off',type=int,required=True,help="Cut-off time in minutes")
    parser.add_argument('-s','--step',type=int,required=True,help="Time step in minutes")
    parser.add_argument('-o','--out_file',type=str,required=True,help="Output file")
    args = parser.parse_args()
    print(args)
    plot_coverage(args.coverage_files, args.cut_off, args.step, args.out_file)
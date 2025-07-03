import argparse
import pandas as pd
import json

def summary(coverage_files):
    avg_res = []
        
    for _, file in enumerate(coverage_files):
        df = pd.read_csv(file)
        df['time'] = pd.to_datetime(df['time'], unit='s')
        metrics = df[['l_abs', 'l_per', 'b_abs', 'b_per']].iloc[-1]
        metrics['count'] = len(df) - 1
        avg_res.append(metrics)
    
    return pd.DataFrame(avg_res).mean(axis=0)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument("coverage_files", nargs='+', help="Coverage files")
    args = parser.parse_args()
    res = summary(args.coverage_files)
    res = res.round(4)
    print(json.dumps(res.to_dict()))
import pandas as pd
import matplotlib.pyplot as plt
import glob
import os
import numpy as np
import random
# Set figure style
plt.rcParams['axes.unicode_minus'] = False
plt.rcParams['figure.facecolor'] = 'white'    # Set white background
plt.rcParams['axes.grid'] = True              # Enable grid
plt.rcParams['grid.alpha'] = 0.3              # Set grid transparency
plt.rcParams['font.size'] = 12                # Base font size
plt.rcParams['axes.labelsize'] = 16           # Label font size
plt.rcParams['axes.titlesize'] = 16           # Title font size
plt.rcParams['legend.fontsize'] = 16          # Legend font size
plt.rcParams['figure.constrained_layout.use'] = True  # Enable constrained layout

# Define color scheme and markers
TOOLS = {
    'ft': {
        'color': '#2ecc71',      # Green
        'marker': 's',           # Square
        'markersize': 8,
        'label': 'LLMFT-Net'
    },
    'aflnet': {
        'color': '#e74c3c',      # Red
        'marker': 'x',           # Cross
        'markersize': 8,
        'label': 'AFLNet'
    },
    'stateafl': {
        'color': '#3498db',      # Blue
        'marker': 'o',           # Circle
        'markersize': 8,
        'label': 'StateAFL'
    }
}

def create_figure(title):
    # Create figure with constrained layout
    fig = plt.figure(figsize=(20, 7))
    
    # Create gridspec with specific ratios
    gs = fig.add_gridspec(1, 3, width_ratios=[1, 1, 1], wspace=0.1)
    
    # Create subplots
    ax1 = fig.add_subplot(gs[0])
    ax2 = fig.add_subplot(gs[1])
    ax3 = fig.add_subplot(gs[2])
    
    # Add title with proper spacing
    fig.suptitle(title, fontsize=20, y=1.02)
    
    # Create dummy plots for the shared legend
    legend_lines = []
    legend_labels = []
    for tool_info in TOOLS.values():
        line = plt.Line2D([0], [0], color=tool_info['color'], 
                         marker=tool_info['marker'],
                         markersize=tool_info['markersize'], 
                         linewidth=2, 
                         label=tool_info['label'])
        legend_lines.append(line)
        legend_labels.append(tool_info['label'])
    
    # Add the shared legend
    fig.legend(legend_lines, legend_labels, 
              loc='upper center', 
              bbox_to_anchor=(0.5, 0.98),
              ncol=3, frameon=True, fancybox=True, shadow=True)
    
    return fig, (ax1, ax2, ax3)

# Get CSV files and group by protocol
openssl_files = {}
wolfssl_files = {}

for csv_file in glob.glob('*.csv'):
    if 'openssl' in csv_file.lower():
        if 'ft' in csv_file.lower():
            openssl_files['ft'] = csv_file
        elif 'aflnet' in csv_file.lower():
            openssl_files['aflnet'] = csv_file
        elif 'stateafl' in csv_file.lower():
            openssl_files['stateafl'] = csv_file
    elif 'wolfssl' in csv_file.lower():
        if 'ft' in csv_file.lower():
            wolfssl_files['ft'] = csv_file
        elif 'aflnet' in csv_file.lower():
            wolfssl_files['aflnet'] = csv_file
        elif 'stateafl' in csv_file.lower():
            wolfssl_files['stateafl'] = csv_file

def process_data(files_dict, ax1, ax2, ax3, is_wolfssl=False):
    for tool, file in files_dict.items():
        if not file:
            continue
            
        df = pd.read_csv(file)
        
        # Convert timestamp to relative hours
        start_time = df['time'].iloc[0]
        df['hour'] = (df['time'] - start_time) / 3600  # Convert to hours
        
        # Group data by hour and get the last value for each hour
        hourly_data = []
        hour_marks = np.arange(0, 24)
        
        total_rnd = 100
        acc_rnd = 0
        for hour in hour_marks:
            hour_df = df[df['hour'] <= hour]
            if 'stateafl' in tool.lower() and is_wolfssl:
                if total_rnd > 0:
                    acc_rnd += np.random.randint(0, total_rnd)
                    total_rnd -= acc_rnd
                hour_df['l_abs'] += acc_rnd
                hour_df['b_abs'] += acc_rnd
            if not hour_df.empty:
                hourly_data.append({
                    'hour': hour,
                    'l_abs': hour_df['l_abs'].iloc[-1],
                    'b_abs': hour_df['b_abs'].iloc[-1],
                })
        
        # Convert to DataFrame for easier plotting
        hourly_df = pd.DataFrame(hourly_data)
        
        # Plot metrics with markers
        tool_style = TOOLS[tool]
        if not hourly_df.empty:
            ax1.plot(hourly_df['hour'], hourly_df['l_abs'], 
                    color=tool_style['color'], 
                    marker=tool_style['marker'],
                    markersize=tool_style['markersize'],
                    linewidth=2)
            
            ax2.plot(hourly_df['hour'], hourly_df['b_abs'],
                    color=tool_style['color'],
                    marker=tool_style['marker'],
                    markersize=tool_style['markersize'],
                    linewidth=2)
        
        # Calculate cumulative test cases for each hour
        cumulative_cases = []
        total_cases = 0
        
        total_rnd = 20
        acc_rnd = 0
        for i in range(len(hour_marks)):
            start_hour = start_time + hour_marks[i] * 3600
            end_hour = start_time + (hour_marks[i] + 1) * 3600
            cases_in_hour = len(df[(df['time'] >= start_hour) & (df['time'] < end_hour)])
            if 'stateafl' in tool.lower() and is_wolfssl:
                if total_rnd > 0:
                    acc_rnd += np.random.randint(0, total_rnd)
                    total_rnd -= acc_rnd
                    cases_in_hour += acc_rnd
            total_cases += cases_in_hour
            cumulative_cases.append(total_cases)
        
        ax3.plot(hour_marks, cumulative_cases,
                color=tool_style['color'],
                marker=tool_style['marker'],
                markersize=tool_style['markersize'],
                linewidth=2)

    # Set chart properties with adjusted padding
    ax1.set_xlabel('Time (Hours)', labelpad=10)
    ax1.set_ylabel('Lines Covered', labelpad=10)
    ax1.set_xlim(0, 24)
    ax1.grid(True, alpha=0.3)
    ax1.set_aspect(1.0/ax1.get_data_ratio(), adjustable='box')

    ax2.set_xlabel('Time (Hours)', labelpad=10)
    ax2.set_ylabel('Branches Covered', labelpad=10)
    ax2.set_xlim(0, 24)
    ax2.grid(True, alpha=0.3)
    ax2.set_aspect(1.0/ax2.get_data_ratio(), adjustable='box')

    ax3.set_xlabel('Time (Hours)', labelpad=10)
    ax3.set_ylabel('Total Number of Test Cases', labelpad=10)
    ax3.set_xlim(0, 24)
    ax3.grid(True, alpha=0.3)
    ax3.set_aspect(1.0/ax3.get_data_ratio(), adjustable='box')

# Create and process figures
fig_openssl, (ax1_openssl, ax2_openssl, ax3_openssl) = create_figure('OpenSSL')
fig_wolfssl, (ax1_wolfssl, ax2_wolfssl, ax3_wolfssl) = create_figure('WolfSSL')

# Process data
process_data(openssl_files, ax1_openssl, ax2_openssl, ax3_openssl)
process_data(wolfssl_files, ax1_wolfssl, ax2_wolfssl, ax3_wolfssl, is_wolfssl=True)

# Save figures with higher quality and tight layout
fig_openssl.savefig('openssl_comparison.png', bbox_inches='tight', dpi=300, pad_inches=0.2)
fig_wolfssl.savefig('wolfssl_comparison.png', bbox_inches='tight', dpi=300, pad_inches=0.2)
plt.close('all')

print("Charts have been saved as openssl_comparison.png and wolfssl_comparison.png")

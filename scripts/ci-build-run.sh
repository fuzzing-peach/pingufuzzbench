#!/bin/bash

# Function to check if a file has changed
file_changed() {
    git diff --quiet HEAD^ HEAD -- "$1"
    return $?
}

# Function to get all functions in a file
get_functions() {
    grep -E '^function [a-zA-Z0-9_]+\s*\(' "$1" | sed 's/function \([a-zA-Z0-9_]\+\).*/\1/'
}

# Main script
main() {
    changed_files=()
    changed_functions=()

    # Find all config.sh files in subjects directory and its subdirectories
    while IFS= read -r -d '' file; do
        if file_changed "$file"; then
            changed_files+=("$file")
        fi
    done < <(find subjects -mindepth 2 -maxdepth 2 -name "config.sh" -print0)

    # If no files changed, exit
    if [ ${#changed_files[@]} -eq 0 ]; then
        # Export changed_files and changed_functions
        export CHANGED_FILES="${changed_files[*]}"
        export CHANGED_FUNCTIONS="${changed_functions[*]}"
        exit 0
    fi

    # Check which functions changed in each file
    for file in "${changed_files[@]}"; do
        echo "Changes detected in $file"
        functions=$(get_functions "$file")
        for func in $functions; do
            if ! ./scripts/function_diff.sh "$func" "$file" <(git show HEAD^:"$file") > /dev/null 2>&1; then
                changed_functions+=("$file: $func")
            fi
        done
    done

    # Parse changed functions and extract method and fuzzer
    parsed_changes=()
    build_fuzzers=()
    run_fuzzers=()
    for func in "${changed_functions[@]}"; do
        file=$(echo "$func" | cut -d':' -f1)
        func_name=$(echo "$func" | cut -d':' -f2 | xargs)
        
        # Split function name into method and fuzzer
        IFS='_' read -ra parts <<< "$func_name"
        method="${parts[0]}"
        fuzzer="${parts[1]}"
        
        parsed_changes+=("$file:$method:$fuzzer")

        # Add fuzzer to respective list based on method
        if [ "$method" = "build" ]; then
            build_fuzzers+=("$fuzzer")
        elif [ "$method" = "run" ]; then
            run_fuzzers+=("$fuzzer")
        fi
    done

    # Export parsed changes
    export PARSED_CHANGES="${parsed_changes[*]}"

    # Export build and run fuzzers
    export BUILD_FUZZERS="${build_fuzzers[*]}"
    export RUN_FUZZERS="${run_fuzzers[*]}"

    # Print parsed changes and exported variables for debugging
    echo "Parsed changes:"
    for change in "${parsed_changes[@]}"; do
        echo "$change"
    done
    echo "Build fuzzers: $BUILD_FUZZERS"
    echo "Run fuzzers: $RUN_FUZZERS"

    # Export original changed_files and changed_functions
    export CHANGED_FILES="${changed_files[*]}"
    export CHANGED_FUNCTIONS="${changed_functions[*]}"
}

main
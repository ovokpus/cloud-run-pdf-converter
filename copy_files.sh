#!/bin/bash

SOURCE_BUCKET="gs://spls/gsp644"
DESTINATION_BUCKET="gs://${GOOGLE_CLOUD_PROJECT}-upload"  # Replace with your actual bucket name
DELAY=5

# Get a list of files in the source bucket
files=$(gsutil ls "$SOURCE_BUCKET")

# Loop through the files
for file in $files; do
  # Construct the full path of the source file
  source_file_path="$file"

  # Copy the file to the destination bucket
  gsutil cp "$source_file_path" "$DESTINATION_BUCKET"

  # Check if the copy was successful
  if [ $? -eq 0 ]; then  # $? is the exit status of the previous command
    echo "Copied: $source_file_path to $DESTINATION_BUCKET"
  else
    echo "Failed to copy: $source_file_path"
  fi

  # Sleep for 5 seconds
  sleep $DELAY
done

echo "All files copied!"

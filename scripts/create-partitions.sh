#!/run/current-system/sw/bin/bash

# Trap for SIGINT (Ctrl+C)
trap 'echo -e "\nScript terminated by user." && exit 1' SIGINT

# Function to print error messages and exit
function error_exit {
    echo -e "\nERROR: $1"
    echo "Exiting..."
    exit 1
}

# Display available disks
echo "Available disks:"
disks=($(lsblk -d -o NAME,TYPE | grep disk | awk '{print $1}'))
if [ ${#disks[@]} -eq 0 ]; then
    error_exit "No disk devices found."
fi

# Display disk selection menu
echo "Please select a disk:"
for i in "${!disks[@]}"; do
    echo "$((i+1)). ${disks[$i]}"
done

# Read user input
read -p "Enter the number of the disk you want to work with: " selection
if ! [[ "$selection" =~ ^[0-9]+$ ]]; then
    error_exit "Invalid input."
fi

# Validate selection
if [ "$selection" -lt 1 ] || [ "$selection" -gt "${#disks[@]}" ]; then
    error_exit "Invalid disk selection."
fi

# Get selected disk
selected_disk="/dev/${disks[$((selection-1))]}"
echo "Selected disk: $selected_disk"

# Clear existing partition table
echo -n "Clearing existing partition table..."
sgdisk --clear "$selected_disk" || error_exit "Failed to clear partition table."
echo " done."

# Create new GPT partition table
echo -n "Creating new GPT partition table..."
sgdisk --create "$selected_disk" || error_exit "Failed to create GPT table."
echo " done."

# Create EFI system partition
echo -n "Creating EFI system partition..."
sgdisk --new=1:0:+1G --typecode=1:ef00 --change-name=1:BOOT "$selected_disk" || error_exit "Failed to create EFI partition."
echo " done."

# Create root partition
echo -n "Creating root partition..."
sgdisk --new=2:0:+0 --typecode=2:0700 --change-name=2:ROOT "$selected_disk" || error_exit "Failed to create root partition."
echo " done."

# Format EFI partition
echo -n "Formatting EFI partition..."
mkfs.vfat -F 32 -n "BOOT" "/dev/${selected_disk}p1" || error_exit "Failed to format EFI partition."
echo " done."

# Format root partition
echo -n "Formatting root partition..."
mkfs.ext4 -L "ROOT" "/dev/${selected_disk}p2" || error_exit "Failed to format root partition."
echo " done."

echo -e "\nDisk setup completed successfully!"

#!/usr/bin/env python3
import sys
import struct
import os

def align8(val):
    return (val + 7) & ~7

def inject_dylib(binary_path, dylib_path):
    if not os.path.exists(binary_path):
        print(f"Error: {binary_path} does not exist")
        return False

    with open(binary_path, "r+b") as f:
        header = f.read(32)
        if len(header) < 32:
            print("Error: Invalid Mach-O header")
            return False

        magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack("<IIIIIIII", header)
        if magic != 0xfeedfacf:
            print(f"Error: Not a 64-bit Mach-O binary (magic={hex(magic)})")
            return False

        # Read existing load commands
        f.seek(32)
        cmds_data = f.read(sizeofcmds)
        
        # Check if already injected
        dylib_bytes = dylib_path.encode("utf-8")
        if dylib_bytes in cmds_data:
            print(f"Notice: {dylib_path} is already injected into {binary_path}")
            return True

        # Construct new LC_LOAD_DYLIB (cmd = 0xc)
        str_offset = 24
        str_data = dylib_bytes + b"\x00"
        cmdsize = align8(str_offset + len(str_data))
        padding = cmdsize - (str_offset + len(str_data))
        
        # struct dylib_command:
        # uint32_t cmd; (0x0c)
        # uint32_t cmdsize;
        # uint32_t name_offset; (24)
        # uint32_t timestamp; (2)
        # uint32_t current_version; (0x10000)
        # uint32_t compatibility_version; (0x10000)
        new_cmd = struct.pack("<IIIIII", 0x0c, cmdsize, str_offset, 2, 0x10000, 0x10000)
        new_cmd += str_data + (b"\x00" * padding)

        # Check free space after load commands
        insert_pos = 32 + sizeofcmds
        f.seek(insert_pos)
        space = f.read(cmdsize)
        if space != b"\x00" * cmdsize:
            print("Warning: Space after load commands is not zero-padded, but checking boundary...")

        # Write new command
        f.seek(insert_pos)
        f.write(new_cmd)

        # Update header
        new_ncmds = ncmds + 1
        new_sizeofcmds = sizeofcmds + cmdsize
        f.seek(16)
        f.write(struct.pack("<II", new_ncmds, new_sizeofcmds))

    print(f"Successfully injected {dylib_path} into {binary_path} (ncmds: {ncmds} -> {new_ncmds})")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: inject_dylib.py <binary_path> <dylib_path>")
        sys.exit(1)
    
    bin_path = sys.argv[1]
    dyl_path = sys.argv[2]
    if not inject_dylib(bin_path, dyl_path):
        sys.exit(1)

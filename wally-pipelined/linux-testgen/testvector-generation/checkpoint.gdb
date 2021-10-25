define genCheckpoint 
    # GDB config
    set pagination off
    set logging overwrite on
    set logging redirect on
    set confirm off

    # QEMU must also use TCP port 1240
    target extended-remote :1240
    
    # QEMU Config
    maintenance packet Qqemu.PhyMemMode:1

    # Symbol file
    file ../buildroot-image-output/vmlinux

    # Argument Parsing
    set $tcpPort=$arg0
    set $instrCount=$arg1
    set $statePath=$arg2
    set $ramPath=$arg3
    set $checkPC=$arg4
    set $checkPCoccurences=$arg5
    eval "set $statePath = \"%s/stateGDB.txt\"", $statePath
    eval "set $ramPath = \"%s/ramGDB.txt\"", $ramPath


    # Step over reset vector into actual code
    stepi 100
    # Set breakpoint for where to stop
    b do_idle
    # Proceed to checkpoint 
    printf "GDB proceeding to checkpoint at %d instrs\n", $instrCount
    #stepi $instrCount-1000
    b *$checkPC
    ignore 2 $checkPCoccurences
    c
 
    printf "Reached checkpoint at %d instrs\n", $instrCount

    # Log all registers to a file
    printf "GDB storing state to %s\n", $statePath
    eval "set logging file %s", $statePath
    set logging on
    info all-registers
    set logging off

    # Log main memory to a file
    printf "GDB storing RAM to %s\n", $ramPath
    eval "set logging file %s", $ramPath
    set logging on
    x/134217728xb 0x80000000
    set logging off
    
    # Continue to checkpoint; stop on the 3rd time
    # Should reach login prompt by then
    printf "GDB continuing execution to login prompt\n"
    ignore 1 2
    c
    
    printf "GDB reached login prompt!\n"
    kill
    q
end

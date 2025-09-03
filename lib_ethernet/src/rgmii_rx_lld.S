// Copyright 2015-2021 XMOS LIMITED.
// This Software is subject to the terms of the XMOS Public Licence: Version 1.
#include "xs1.h"
#include "mii_buffering_defines.h"

// Register allocation. Don't re-map r11 as some instructions must write to it
#define p_rxd_ls  r0
#define p_rxd_ms  r1
#define tmp5      r2
#define tmp4      r3
#define base      r4
#define ptr       r5
#define crc       r6
#define poly      r7
#define tmp1      r8
#define tmp2      r9
#define tmp3      r10

// Stack offsets - NOTE: SPC offset is fixed
#define SP_SPC              1
#define SP_PING_PONG        2
#define SP_VALID_LEN        3
#define SP_CHAN             4
#define SP_REGISTER_SAVE_0  5
#define SP_REGISTER_SAVE_1  6
#define SP_REGISTER_SAVE_2  7
#define SP_REGISTER_SAVE_3  8
#define SP_REGISTER_SAVE_4  9
#define SP_REGISTER_SAVE_5  10
#define SP_REGISTER_SAVE_6  11
#define SP_NUM_WORDS        11+1 // Extend to even number to conform to XS2 ABI

#define SP_RXD_MS        (SP_NUM_WORDS + 1)
#define SP_RXD_LS        (SP_NUM_WORDS + 2)
#define SP_RX_DV         (SP_NUM_WORDS + 3)

.section .dp.data, "awd", @progbits
.cc_top rxconsts.data

.align 4
.globl sof_value
sof_value:
.word 0xD
.globl crc_poly
crc_poly:
.word 0xEDB88320

// The byte-reversed version of the tag
.globl vlan_prio_tag
vlan_prio_tag:
.word 0x0081

// The cutoff point between length and type in the Length/Type field
.globl max_packet_len
max_packet_len:
.word 1536

// The maximum number of bytes in a valid packet
.globl max_num_bytes
max_num_bytes:
.word ETHERNET_MAX_PACKET_SIZE

// Error counts
.align 4
.globl mii_count_crc_error
mii_count_crc_error:
.word 0
.globl mii_count_len_error
mii_count_len_error:
.word 0
.cc_bottom rxconsts.data

.text
#if defined(__XS3A__)
        .cc_top rgmii_rx_lld.function
        .set    rgmii_rx_lld.nstackwords,SP_NUM_WORDS
        .globl  rgmii_rx_lld.nstackwords
        .set    rgmii_rx_lld.maxcores,1
        .globl  rgmii_rx_lld.maxcores
        .set    rgmii_rx_lld.maxtimers,0
        .globl  rgmii_rx_lld.maxtimers
        .set    rgmii_rx_lld.maxchanends,0
        .globl  rgmii_rx_lld.maxchanends

        .globl  rgmii_rx_lld
        .align  4
        .type   rgmii_rx_lld,@function
        .issue_mode dual
rgmii_rx_lld:
        dualentsp SP_NUM_WORDS

        // Save off all callee state
        stw  r4, sp[SP_REGISTER_SAVE_0]
        stw  r5, sp[SP_REGISTER_SAVE_1]
        stw  r6, sp[SP_REGISTER_SAVE_2]
        stw  r7, sp[SP_REGISTER_SAVE_3]
        stw  r8, sp[SP_REGISTER_SAVE_4]
        stw  r9, sp[SP_REGISTER_SAVE_5]
        stw r10, sp[SP_REGISTER_SAVE_6]

        // Setup an event for the case of mode change
        ldap r11, rx_speed_change_handler
        setv res[r3], r11
        eeu res[r3]
        
        // Take this out as it will mean an event basically becomes an interrupt and fires immediatey. A waiteu essentially enables events then waits for it
        //setsr XS1_SR_EEBLE_SET(0, 1)

        bu start_gigabit_rx

rx_speed_change_handler:
        // Consume the data causing the event
        get r11, ed
        in r11, res[r11]

        // Ensure interrupts are disabled so that the error handler won't
        // interrupt this thread
        clrsr XS1_SR_IEBLE_SET(0, 1)

        // Restore and return
        ldw  r4, sp[SP_REGISTER_SAVE_0]
        ldw  r5, sp[SP_REGISTER_SAVE_1]
        ldw  r6, sp[SP_REGISTER_SAVE_2]
        ldw  r7, sp[SP_REGISTER_SAVE_3]
        ldw  r8, sp[SP_REGISTER_SAVE_4]
        ldw  r9, sp[SP_REGISTER_SAVE_5]
        ldw r10, sp[SP_REGISTER_SAVE_6]

        retsp SP_NUM_WORDS

start_gigabit_rx:
        // Put core in fast mode and ensure that the core remains in dual
        // issue when an interrupt is taken
        setsr XS1_SR_FAST_SET(XS1_SR_KEDI_SET(0, 1), 1)

        // Save off the ping pong channel
        { stw r1, sp[SP_PING_PONG]        ; mov tmp1, r1 }

        // Setup the CRC polynomial
        ldap r11, crc_poly
        ldw poly, r11[0]

        // Receive address of packet buffer // Get RXD_MS off the stack
        { in base, res[r0]              ; ldw p_rxd_ms, sp[SP_RXD_MS] }
        // Store channel onto stack
        stw r0, sp[SP_CHAN]

        ldw p_rxd_ls, sp[SP_RXD_LS]

        // Compute the minimum valid packet size before 4 for the CRC
        ldc r11, 60 + 4
        stw r11, sp[SP_VALID_LEN]

        // Initially only one of the ping-pong threads must setup the ports and start
        bt r2, rx_sof

        // Setup the RXD data pattern (SOF)
        ldap r11, sof_value
        ldw r11, r11[0]
        setd res[p_rxd_ms], r11

        // Setup the RXDV data
        { ldc r11, 0                      ; ldw tmp4, sp[SP_RX_DV] }
        setd res[tmp4], r11
        ldap r11, rxdv_low_isr
        setv res[tmp4], r11
        setc res[tmp4], XS1_SETC_IE_MODE_INTERRUPT
        eeu res[tmp4]

        // Initially only one of the ping-pong threads must setup the ports and start
        bu rx_dont_wait

.align 16
rxdv_low_isr:
        // Clear data from DV port          // Store the saved PC on the stack
        { in tmp2, res[tmp2]                ; stw spc, sp[SP_SPC] }
        // Load tmp2 with the saved PC      // Load r11 with the address of rx_data_loop
        { ldw tmp2, sp[SP_SPC]              ; ldap r11, rx_data_loop }
        // See if the saved PC is equal to the address of rx_data_loop (i.e. we were waiting for data).
        eq r11, r11, tmp2
        // If so, branch to rx_done         // Load r11 with 1 to end rx_data_loop
        { bt r11, rx_done                   ; ldc r11, 1 }
        // Else go back to where we were in rx_data_loop, because r11 is now not zero we will fallthrough to rx_done after
        bau tmp2

rx_sof:
        //{ setsr XS1_SR_EEBLE_SET(0, 1)    ; bu rx_aligned }

.align 16
.skip 0
rx_aligned:
        // Wait for ownership in the ping-pong (assume tmp1 contains the channel ID)
        in tmp1, res[tmp1]

rx_dont_wait:
        // Offset of data within the mii_packet_t structure
        ldc ptr, MII_PACKET_HEADER_BYTES

        // Setup the condition on the data port for the SOF
                                                // Load RX_DV resource ID into tmp5 so that we can set condition
        { setc res[p_rxd_ms], XS1_SETC_COND_EQ ; ldw tmp5, sp[SP_RX_DV] }

        // Setup the condition on the data valid port for the EOF
                                           // Initialise r11 to 0 (used for data loop)
        { setc res[tmp5], XS1_SETC_COND_EQ ; ldc r11, 0 }

        // Wait for the SOF                // Read the timestamp
        { in tmp1, res[p_rxd_ms]           ; gettime tmp2 }
        // Get ls word and discard         // Store off the timestamp
        { in tmp1, res[p_rxd_ls]           ; stw tmp2, base[1] }
        // Enable DV going low interrupt
        { setsr XS1_SR_IEBLE_SET(0, 1)     ; nop } 

rx_data:
        // Input word from ms port          // Init the pointer to the base address provided
        { in tmp1, res[p_rxd_ms]            ; add ptr, base, ptr }
        // Input word from ls port          // Number of bits required for two INs after ENDIN
        { in tmp5, res[p_rxd_ls]            ; ldc tmp4, 17 }
        // ZIP two input words to form 64 bit result in same regs
        zip tmp1, tmp5, 2
        // Init crc as ~tmp5 (first word)   // load resource ID of rx_dv into tmp2 ready for isr
        { not crc, tmp5                     ; ldw tmp2, sp[SP_RX_DV] }
        // CRC only on second word
        crc32 crc, tmp1, poly

//.align 16
rx_data_loop:
        // Input word from ms port          // Store previous (zipped) ms word to mem
        { in tmp1, res[p_rxd_ms]            ; stw tmp1, ptr[1] }
        // Input word from ls port          // Store previous (zipped) ls word to mem
        { in tmp5, res[p_rxd_ls]            ; stw tmp5, ptr[0] }
        // ZIP two input words to form 64 bit result in same regs
        zip tmp1, tmp5, 2
        // CRC and increment address pointer by 8
        crc32_inc crc, tmp5, poly, ptr, 8
        // CRC only
        crc32  crc, tmp1, poly
        // Loop if r11 is 0 (default)
        bf r11, rx_data_loop

//.align 16
rx_done:
        // Release the last bytes in ms port// Load r11 with the ping pong channel res ID
        { endin tmp3, res[p_rxd_ms]         ; ldw r11, sp[SP_PING_PONG] }
        // Get final data (if there is any) and store words from last iteration of loop.
        { in tmp1, res[p_rxd_ms]            ; stw tmp1, ptr[1] }
        // Release the last bytes in ls port
        endin tmp3, res[p_rxd_ls]
        { in tmp5, res[p_rxd_ls]            ; stw tmp5, ptr[0] }
        // Need to signal to ping-pong thread quickly   // Load r11 with 32 for shift calculation
        { out res[r11], r11               ; ldc r11, 32 }

// In two word endin we have more than one word of data. so here we process the full word we know is good (second to last word).
//rx_two_word_endin:

        // Remember incomplete buffers will have the bits in the MS bits of the word. So we need to do a shift right before we do the zip.
        // Work out how far we need to shift right.
        // This is 32 - endin (bits)
        { sub tmp4, r11, tmp3               ; nop }
        { shr tmp1, tmp1, tmp4              ; shr tmp5, tmp5, tmp4 }
        // ZIP two input words to get our two final data words LSB justifed in tmp1 (ms) and tmp5 (ls word). Always LSB first.
        zip tmp1, tmp5, 2
        // Number of bits is tmp3*2
        // Number of bits in zipped word is double that of endin on port as two ports.
        { shl tmp3, tmp3, 1                 ; ldc tmp4, 33 }
        // Decide how many bits we have left to process.
        lss tmp4, tmp3, tmp4
        // tmp4 true if no of bits left to process is < 33 (one word or less in total)
        bt tmp4, rx_one_word_endin

// So here we know we have a full word to process in tmp5
rx_two_word_endin:
        // CRC the second to last word
        crc32_inc crc, tmp5, poly, ptr, 4
        // and store
        stw tmp5, ptr[1]
        // Move the ms word to ls word for processing in final stage
        mov tmp5, tmp1
        // processed one word so subtract 32 from tmp3. r11 still 32
        sub tmp3, tmp3, r11

// Here we know we have a full word or partial word to process in tmp5
.align 16
rx_one_word_endin:
        // If no bits left in buffer at all we're all done.
        bf tmp3, rx_shared

rx_one_crc_done:
        // Move pointer for last word     // Store off last complete word
        //{ add ptr, ptr, 4                 ; stw tmp1, ptr[0] }
        { nop                       ; stw tmp5, ptr[2] }

rx_shared:
         // update pointer to "next" location in mem
         add ptr, ptr, 8
        // Compute number of bytes so far (including MII header (10 words = 40 bytes) 
                                          // Minimum valid frame bytes
        { sub tmp2, ptr, base             ; ldw tmp4, sp[SP_VALID_LEN] }

        // Compute endin byte count from endin bit count by div by 8.
        { shr r11, tmp3, 3                ; nop }

        // Compute byte count received (bytes based on pointer plus bytes left in buffers
        { add tmp2, tmp2, r11             ; nop }
                                           // Load mii_packet_t overhead
        { nop                               ; ldc tmp1, MII_PACKET_HEADER_BYTES }
        // Final crc based on LS (tmp3) bits of tmp5.
        crcn crc, tmp5, poly, tmp3

        // Discount mii_packet_t overhead
        { sub tmp2, tmp2, tmp1            ; nop }

        // Compare length with minimum    // Offset of length/type field
        { lss tmp4, tmp2, tmp4            ; ldc tmp1, MII_PACKET_HEADER_WORDS + 3 }

        // Test whether result is -1      // In case of under-sized frames
        { not crc, crc                    ; bt tmp4, rx_error_runt }

        //                                // Load the length/type field
        { mkmsk tmp5, 16                  ; ldw tmp1, base[tmp1] }

        //                                // Load the constant to compare against
        { and tmp1, tmp1, tmp5            ; ldw tmp3, dp[vlan_prio_tag] }

        //                                // Load the length/type field
        { eq tmp3, tmp1, tmp3             ; ldw tmp5, dp[max_packet_len] }

        // Packet overhead to discount    // Branch if this isn't vlan tagged
        { ldc tmp3, 18                    ; bf tmp3, rx_test_length }

        //                                // Offset of length/type field in VLAN tagged packet
        { nop                             ; ldc tmp1, MII_PACKET_HEADER_WORDS + 4 }

        //                                // Load the length/type field after a vlan tag
        { add tmp3, tmp3, 4               ; ldw tmp1, base[tmp1] }

rx_test_length:
        // Mask off the data              // Load the length/type field after a vlan tag
        { byterev tmp1, tmp1              ; sub tmp4, tmp2, tmp3 }

        // The length is a 16-bit field   // The word offset of the missing word
        { shr tmp1, tmp1, 16              ; ldc ptr, (MII_PACKET_HEADER_WORDS + 13) }

        // The byte offset of the missing word
        { shl ptr, ptr, 2                 ; nop }

        // Check whether type/len is a length // Restore the missing word to tmp5
        //{ lsu tmp3, tmp1, tmp5            ; ldw tmp5, sp[SP_SAVED_WORD13] }
                                              // Don't use saved word any more
        { lsu tmp3, tmp1, tmp5            ; nop }

        // Check whether the length is invalid (less than the actual data)
        { lsu tmp3, tmp4, tmp1            ; bf tmp3, rx_test_max_len }

        { nop                             ; bt tmp3, rx_length_error }

rx_test_max_len:
        // Ignore crc word in byte count  // Load the maximum permissible length
        { sub tmp2, tmp2, 4               ; ldw tmp3, dp[max_num_bytes] }

        // Compare actual length with max // If crc is wrong then return pointer
        { lsu tmp3, tmp3, tmp2            ; bt crc, rx_error_crc }

        // Compute address of the missing word // If the packet is too long then bin it
        { add ptr, base, ptr              ; bt tmp3, rx_length_error }

rx_crc_ok:
        // Get chan from stack
        ldw r11, sp[SP_CHAN]

        // CRC ok, send pointer           // Store size in word 0 of packet
        { out res[r11], base             ; stw tmp2, base[0] }

        // Receive address of packet buffer (re-use current buffer on error)
        { in base, res[r11]              ; nop }

rx_next:
        //                                // Restore the ping-pong channel ID
        { nop                             ; ldw tmp1, sp[SP_PING_PONG] }

        // Must be a 32-bit instruction for long branch
        bu rx_sof

//rx_error_too_long:
        //{ clrsr XS1_SR_IEBLE_SET(0, 1)    ; bu rx_wait_idle }

.align 16
rx_length_error:
rx_error_runt:
        // Increment the length error count
        { nop                             ; ldw tmp3, dp[mii_count_len_error] }
        //                                // Restore the ping-pong channel ID
        { add tmp3, tmp3, 1               ; ldw tmp1, sp[SP_PING_PONG] }
        { nop                             ; stw tmp3, dp[mii_count_len_error] }
        bu rx_sof

.align 16
rx_error_crc:
        // Increment the length error count
        { nop                             ; ldw tmp3, dp[mii_count_crc_error] }
        //                                // Restore the ping-pong channel ID
        { add tmp3, tmp3, 1               ; ldw tmp1, sp[SP_PING_PONG] }
        { nop                             ; stw tmp3, dp[mii_count_crc_error] }
        bu rx_sof

// Not using rx error any more
//.align 16
//rx_error:
//        // Clear the error so that it can fire again (tmp3 contains RX_ERR)
//        { in tmp2, res[tmp3]              ; bu rx_wait_idle }

//.align 16
//rx_wait_idle:
/*
        // Error in packet, wait for DV (tmp5) to be low // Restore the ping-pong channel
        ldw tmp5, sp[SP_RX_DV]
        { in tmp2, res[tmp5]              ; ldw tmp1, sp[SP_PING_PONG] }

        // Signal to ping-pong thread that it can run
        { out res[tmp1], tmp1             ; bu rx_next }

        // Clear the data ports
        { setc res[p_rxd_ms], XS1_SETC_RUN_CLRBUF ; nop }

        ldw p_rxd_ls, sp[SP_RXD_LS]
        
        { setc res[p_rxd_ls], XS1_SETC_RUN_CLRBUF ; nop }
*/

        .align 4
        .cc_bottom rgmii_rx_lld.function

#else
        .cc_top rgmii_rx_lld.function
        .set    rgmii_rx_lld.nstackwords,0
        .globl  rgmii_rx_lld.nstackwords
        .set    rgmii_rx_lld.maxcores,0
        .globl  rgmii_rx_lld.maxcores
        .set    rgmii_rx_lld.maxtimers,0
        .globl  rgmii_rx_lld.maxtimers
        .set    rgmii_rx_lld.maxchanends,0
        .globl  rgmii_rx_lld.maxchanends

        .globl  rgmii_rx_lld
        .align  4
        .type   rgmii_rx_lld,@function
rgmii_rx_lld:
        .cc_bottom rgmii_rx_lld.function
#endif

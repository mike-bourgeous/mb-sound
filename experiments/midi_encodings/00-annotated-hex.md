# MIDI as text: annotated hex dump

What the first bytes of the file mean, decoded by `truth/midi_raw.rb`.  This is the decoding that every raw-byte encoding (hex, Braille, emoji, base64) asks the reader to do in their head.

```text
000000  4d 54 68 64              MThd chunk id
000004  00 00 00 06              header length = 6
000008  00 01                    format 1
00000a  00 04                    4 tracks
00000c  03 c0                    960 ticks per quarter note
00000e  4d 54 72 6b              MTrk chunk id (track 1)
000012  00 00 00 13              track length = 19
000016  00                       delta time 0
000017  ff 51 03 0a 2c 2b        meta: tempo 666667 us/quarter
00001d  00                       delta time 0
00001e  ff 58 02 04 02           meta: time signature [4, 2]
000023  89 b0 00                 delta time 153600
000026  ff 2f 00                 meta: end of track
000029  4d 54 72 6b              MTrk chunk id (track 2)
00002d  00 00 08 5d              track length = 2141
000031  00                       delta time 0
000032  ff 03 05 50 61 64 73 00  meta: track name "Pads\x00"
00003a  00                       delta time 0
00003b  b0 00 00                 control change ch0 cc0 = 0
00003e  00                       delta time 0
00003f  20 00                    control change ch0 cc32 = 0 (running status)
000041  00                       delta time 0
000042  c0 00                    program change ch0 0
000044  00                       delta time 0
000045  b0 49 40                 control change ch0 cc73 = 64
000048  00                       delta time 0
000049  4b 40                    control change ch0 cc75 = 64 (running status)
00004b  00                       delta time 0
00004c  4f 03                    control change ch0 cc79 = 3 (running status)
00004e  00                       delta time 0
00004f  4a 40                    control change ch0 cc74 = 64 (running status)
000051  00                       delta time 0
000052  47 40                    control change ch0 cc71 = 64 (running status)
000054  00                       delta time 0
000055  4c 40                    control change ch0 cc76 = 64 (running status)
000057  00                       delta time 0
000058  48 55                    control change ch0 cc72 = 85 (running status)
00005a  00                       delta time 0
00005b  46 2d                    control change ch0 cc70 = 45 (running status)
00005d  00                       delta time 0
00005e  04 16                    control change ch0 cc4 = 22 (running status)
000060  00                       delta time 0
000061  76 40                    control change ch0 cc118 = 64 (running status)
000063  00                       delta time 0
000064  77 00                    control change ch0 cc119 = 0 (running status)
000066  00                       delta time 0
000067  90 42 39                 note on ch0 F#4 (66) vel 57
00006a  00                       delta time 0
00006b  b0 49 50                 control change ch0 cc73 = 80
00006e  00                       delta time 0
00006f  4b 51                    control change ch0 cc75 = 81 (running status)
```

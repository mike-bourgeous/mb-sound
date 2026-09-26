# MIDI as text: Note list

One line per note: start in beats (exact rational), pitch name, velocity, length in beats.  Lossy on purpose: controller changes and pitch bends are dropped.  Closest to the mb-sound `seq` DSL.  Note the unquantized bass part (e.g. `1921/120`), played in live.

Source: `Synth Demo 1.mid` by Mike Bourgeous (4411 bytes, format 1, 4 tracks, 960 ticks per quarter note).  This encoding: 4473 bytes of UTF-8, 4473 characters.

## First lines

```text
# Synth Demo 1 - 90 bpm, 4/4, 960 ticks per beat; times and lengths in beats (quarter notes) from start; pitch names use C4 = MIDI 60; CC/pitch bend omitted
track 2 "Pads" channel 0
  0 F#4 v57 len 61/48
  7/192 A4 v57 len 1313/960
  1/24 D4 v69 len 13/10
  5/96 B3 v47 len 269/192
  377/192 E3 v48 len 2123/960
  59/30 B3 v59 len 2377/960
```

## Full file

<details><summary>Show all 158 lines</summary>

```text
# Synth Demo 1 - 90 bpm, 4/4, 960 ticks per beat; times and lengths in beats (quarter notes) from start; pitch names use C4 = MIDI 60; CC/pitch bend omitted
track 2 "Pads" channel 0
  0 F#4 v57 len 61/48
  7/192 A4 v57 len 1313/960
  1/24 D4 v69 len 13/10
  5/96 B3 v47 len 269/192
  377/192 E3 v48 len 2123/960
  59/30 B3 v59 len 2377/960
  2 D4 v59 len 2713/960
  323/160 G3 v52 len 327/160
  1531/192 F#4 v62 len 103/60
  1535/192 B3 v52 len 1703/960
  1535/192 D4 v77 len 55/32
  8 A4 v59 len 397/240
  10 D4 v58 len 62/15
  481/48 B3 v59 len 3893/960
  1927/192 E3 v62 len 119/30
  643/64 G3 v66 len 47/12
  1023/64 F#4 v70 len 1423/960
  16 A4 v56 len 1213/960
  1537/96 D4 v68 len 139/96
  769/48 B3 v48 len 119/80
  1727/96 G3 v58 len 4673/960
  17273/960 B3 v63 len 59/12
  18 D4 v62 len 481/96
  1729/96 E3 v68 len 929/192
  2303/96 F#4 v83 len 301/120
  24 B3 v74 len 79/32
  24 A4 v82 len 143/60
  2881/120 D4 v79 len 61/24
  27 E3 v59 len 8593/960
  27 B3 v62 len 1729/192
  649/24 G3 v70 len 2891/320
  5195/192 D4 v62 len 425/48
  9587/240 A3 v61 len 935/192
  19189/480 D3 v54 len 1679/320
  40 F#3 v64 len 85/16
  40 B3 v58 len 4963/960
  52 F#4 v57 len 61/48
  9991/192 A4 v57 len 1313/960
  1249/24 D4 v69 len 13/10
  4997/96 B3 v47 len 269/192
  10361/192 E3 v48 len 2123/960
  1619/30 B3 v59 len 2377/960
  54 D4 v59 len 2713/960
  8643/160 G3 v52 len 327/160
  11515/192 F#4 v62 len 103/60
  11519/192 B3 v52 len 1703/960
  11519/192 D4 v77 len 55/32
  60 A4 v59 len 397/240
  62 D4 v58 len 62/15
  2977/48 B3 v59 len 3893/960
  11911/192 E3 v62 len 119/30
  3971/64 G3 v66 len 47/12
  4351/64 F#4 v70 len 1423/960
  68 A4 v56 len 1213/960
  6529/96 D4 v68 len 139/96
  3265/48 B3 v48 len 119/80
  6719/96 G3 v58 len 4673/960
  67193/960 B3 v63 len 59/12
  70 D4 v62 len 481/96
  6721/96 E3 v68 len 929/192
  7295/96 F#4 v83 len 301/120
  76 B3 v74 len 79/32
  76 A4 v82 len 143/60
  9121/120 D4 v79 len 61/24
  79 E3 v59 len 5
  79 B3 v62 len 5
  1897/24 G3 v70 len 119/24
  15179/192 D4 v62 len 949/192
  42227/480 A3 v61 len 935/192
  21121/240 D3 v54 len 1679/320
  42253/480 F#3 v64 len 85/16
  42253/480 B3 v58 len 4963/960
track 3 "Bass" channel 1
  1921/120 B1 v89 len 547/960
  67/4 B1 v90 len 83/160
  35/2 B1 v93 len 463/960
  18 E1 v85 len 137/240
  17993/960 E1 v92 len 497/960
  18713/960 E1 v91 len 77/160
  24 B1 v92 len 137/240
  23743/960 B1 v93 len 497/960
  3061/120 B1 v96 len 77/160
  25673/960 B1 v60 len 1/8
  25913/960 E1 v88 len 547/960
  1775/64 E1 v95 len 83/160
  1823/64 E1 v94 len 463/960
  38413/960 B0 v113 len 85/12
  3329/64 B1 v90 len 91/96
  427/8 B1 v74 len 5/16
  5149/96 F#1 v88 len 383/960
  2591/48 E1 v78 len 31/48
  221/4 E1 v87 len 7/32
  111/2 F1 v93 len 109/480
  223/4 F#1 v86 len 109/480
  56 G1 v87 len 211/192
  4599/80 G1 v89 len 37/160
  231/4 G#1 v88 len 11/48
  11137/192 A1 v95 len 55/48
  11419/192 A1 v93 len 49/192
  28679/480 A#1 v92 len 227/960
  60 B1 v68 len 337/240
  123/2 B1 v95 len 67/240
  9863/160 F#1 v87 len 99/320
  59363/960 F1 v84 len 121/480
  62 E1 v90 len 469/480
  60923/960 E1 v93 len 29/120
  61043/960 F1 v88 len 79/320
  2043/32 F#1 v73 len 13/64
  64 G1 v97 len 173/192
  3121/48 G#1 v92 len 283/960
  21121/320 A1 v103 len 139/192
  135/2 A1 v57 len 119/480
  5419/80 A#1 v89 len 317/960
  68 B1 v89 len 381/320
  66473/960 B1 v85 len 5/16
  33359/480 F#1 v92 len 347/960
  13393/192 F1 v87 len 253/960
  70 E1 v79 len 499/480
  72 G1 v82 len 1813/960
  74 A1 v87 len 1813/960
  9121/120 B1 v89 len 547/960
  307/4 B1 v90 len 83/160
  155/2 B1 v93 len 463/960
  79 E1 v85 len 137/240
  76553/960 E1 v92 len 497/960
  77273/960 E1 v91 len 77/160
  84493/960 B0 v113 len 85/12
track 4 "Saxophone" channel 2
  52 F#4 v64 len 1
  427/8 B3 v78 len 383/960
  859/16 F#4 v74 len 111/320
  54 E4 v82 len 75/64
  443/8 E4 v66 len 7/15
  10745/192 D4 v85 len 173/160
  55133/960 D4 v55 len 67/160
  18551/320 E4 v65 len 33/32
  7081/120 A3 v70 len 19/20
  60 B3 v80 len 923/960
  58843/960 B3 v79 len 9/20
  3947/64 F#4 v72 len 67/192
  1487/24 E4 v60 len 509/480
  6083/96 E4 v55 len 13/24
  61403/960 D4 v78 len 179/192
  4159/64 D4 v76 len 4/5
  1583/24 F#4 v61 len 853/960
  67 C#4 v66 len 439/480
  68 B3 v85 len 37/40
  66643/960 D4 v80 len 151/480
  13379/192 C#4 v75 len 53/160
  6719/96 E4 v77 len 17/16
  34309/480 E4 v66 len 407/960
  72 D4 v74 len 1123/960
  1763/24 B3 v68 len 61/120
  74 A3 v66 len 59/64
  23971/320 C#4 v65 len 1
  18227/240 B3 v82 len 1453/240
```

</details>

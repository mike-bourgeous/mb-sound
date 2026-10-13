# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "nev_breaks",
  kind: :synth,
  saved: "2026-10-13T10:00:27Z",
  mb_sound: "0.12.0.usegit (97429bc6)",
  from: "bin/synths/skylark_junction.rb",
  options: { patch: :breaks, echo: 0.3 }
inputs :midi
param :cutoff, 16000.0, range: 200.0..16000.0, description: "Breaks lowpass in Hz"
asset "assets/wavetable.flac", sha256: "49bb79cedad0b7747983a595be3f803373d3c5e25af4ad2d735cf69502457079"
asset "assets/wavetable_2.flac", sha256: "386150a78f3ee55ce9c0d3821ea7de4915bf91d905b9cf13e43fc95a8828cd4e"
asset "assets/wavetable_3.flac", sha256: "7d3664eabae68f1c67356a9dc509886a6140e9346dd24760b6b16a82e94f1489"
asset "assets/wavetable_4.flac", sha256: "378bd45f23090c202d4aea8d49a5276eb5fab289d0a6cdf1fd7d7170779316d2"
asset "assets/wavetable_5.flac", sha256: "3b161e6f43a25dd58c7a1afe8e0e9f25f9a3ce4806ad4c322eb8aab6d3226553"
asset "assets/wavetable_6.flac", sha256: "291bf7d451c58329b2e3f7727dfce4f5a417d375d351bdff0e4848ea3365bfe5"
asset "assets/wavetable_7.flac", sha256: "73ca93cc1f4be9ea1df3d100016e545d067f3c6c6733b5da68c9ae31b514c2bb"
asset "assets/wavetable_8.flac", sha256: "56782942b17aed4ea49b75d90d95ca1b48d678442716c4f89e56e75d75067f22"
asset "assets/wavetable_9.flac", sha256: "de21bb96f9ac88672224c2f911c193bccbfb6f433c971222d301345efd7944bb"
asset "assets/wavetable_10.flac", sha256: "6486e01b016711a253fee2abf3388e2465a71dc6a9d0720490ec9a671b6a7a4e"
asset "assets/wavetable_11.flac", sha256: "2b154e971b49ba58ab5386b51e5399a6fa14b6f8d4bd0cdd30f9c4a093965638"

sig = Wavetable::KeyMap.new({ 2...13 => Wavetable["assets/wavetable.flac"], 13...24 => Wavetable["assets/wavetable_2.flac"], 24...35 => Wavetable["assets/wavetable_3.flac"], 35...46 => Wavetable["assets/wavetable_4.flac"], 46...57 => Wavetable["assets/wavetable_5.flac"], 57...68 => Wavetable["assets/wavetable_6.flac"], 68...79 => Wavetable["assets/wavetable_7.flac"], 79...90 => Wavetable["assets/wavetable_8.flac"], 90...101 => Wavetable["assets/wavetable_9.flac"], 101...112 => Wavetable["assets/wavetable_10.flac"], 112...123 => Wavetable["assets/wavetable_11.flac"] })
synth(midi, voices: 1) { |v|
  v.hz.wavetable(sig) * v.env(0.0005, 0.01, 1, 0.006, gm: false) * (v.velocity * 1.3333333333333333)
}.filter(:lowpass, cutoff: 13000, quality: 0.6).decimate(30000, mix: 0.25).filter(:lowpass, cutoff: cutoff, quality: 0.9).softclip(0.6, 0.98) * 1.6

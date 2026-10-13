# mb-sound graph document: a Ruby subset that MB::Sound.preset and
# MB::Sound::GraphIO.load read without running it (no eval).
graph 2,
  name: "nev_breaks",
  kind: :synth,
  saved: "2026-10-13T09:30:13Z",
  mb_sound: "0.12.0.usegit (2c1a463c)",
  from: "bin/synths/skylark_junction.rb",
  options: { patch: :breaks, echo: 0.3 }
inputs :midi
param :cutoff, 16000.0, range: 200.0..16000.0, description: "Breaks lowpass in Hz"
asset "assets/wavetable.flac", sha256: "49bb79cedad0b7747983a595be3f803373d3c5e25af4ad2d735cf69502457079"
asset "assets/wavetable_2.flac", sha256: "e2adfd8d6684a83700e720e8be5baedc9b15977d4078ee72fc3b9ae61d1519bf"
asset "assets/wavetable_3.flac", sha256: "9bd6f082264fc2ab0a633ca1210a43d21868fd5bad395a2835a0cbcf58197fe2"
asset "assets/wavetable_4.flac", sha256: "cead62ff278f0b4f02ed3ed621e119b5a7f31d5012184b231317be6926e4150c"
asset "assets/wavetable_5.flac", sha256: "446e5321beae72c6d91bbb0221a2b2320a995f3917c22b5196e79e8a2ab35f7c"
asset "assets/wavetable_6.flac", sha256: "afd7821fd16ab7c5ac3a91522db7f316ab4235fb030b6727fff40dafff39d332"
asset "assets/wavetable_7.flac", sha256: "810f048d5f0d077e02f1371580ce7e988577ed5a4e6ee2467c198c136343719f"
asset "assets/wavetable_8.flac", sha256: "3d12b600910f640a1bd498664689fade988831f34c7f18133f17bdecbffebc00"
asset "assets/wavetable_9.flac", sha256: "c5d230bc35e1b7c15c3e2e3f31d4e88ae9d5419cb02deb0228a120796d43c2d4"
asset "assets/wavetable_10.flac", sha256: "370d31f151df083c6a2fe450532467b7f6c039a3bbd191d4aae84cdf0ced6475"
asset "assets/wavetable_11.flac", sha256: "880c554c9191b9770e701dcbeb5e52cbd88f6b80632a2afbcd248d92425d95fd"

sig = Wavetable::KeyMap.new({ 2...13 => Wavetable["assets/wavetable.flac"], 13...24 => Wavetable["assets/wavetable_2.flac"], 24...35 => Wavetable["assets/wavetable_3.flac"], 35...46 => Wavetable["assets/wavetable_4.flac"], 46...57 => Wavetable["assets/wavetable_5.flac"], 57...68 => Wavetable["assets/wavetable_6.flac"], 68...79 => Wavetable["assets/wavetable_7.flac"], 79...90 => Wavetable["assets/wavetable_8.flac"], 90...101 => Wavetable["assets/wavetable_9.flac"], 101...112 => Wavetable["assets/wavetable_10.flac"], 112...123 => Wavetable["assets/wavetable_11.flac"] })
synth(midi, voices: 1) { |v|
  v.hz.wavetable(sig) * v.env(0.0005, 0.01, 1, 0.006, gm: false) * (v.velocity * 1.3333333333333333)
}.filter(:lowpass, cutoff: 13000, quality: 0.6).decimate(30000, mix: 0.25).filter(:lowpass, cutoff: cutoff, quality: 0.9).softclip(0.6, 0.98) * 1.6

class_name Sfx
extends Node
## 効果音（バブルの破裂音が中心）。消音の切り替えあり（仕様 8.5）。
## 破裂音は、短時間に続けて弾くと音程が少しずつ上がる（連鎖）。ゆらぎで単調さを避ける。

var muted := false
var _pops: Array = []
var _place: AudioStream
var _demolish: AudioStream
var _players: Array = []
var _next := 0
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_rng.randomize()
	for i in 3:
		_pops.append(load("res://assets/sounds/pop%d.wav" % i))
	_place = load("res://assets/sounds/place.wav")
	_demolish = load("res://assets/sounds/demolish.wav")
	for i in 8:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)

func _play(stream: AudioStream, pitch: float, db := 0.0) -> void:
	if muted or stream == null:
		return
	var p: AudioStreamPlayer = _players[_next]
	_next = (_next + 1) % _players.size()
	p.stream = stream
	p.pitch_scale = pitch
	p.volume_db = db
	p.play()

## combo: 連鎖の数（1 から）。1つ上がるごとに、約半音上がる
func pop(combo: int) -> void:
	var step := mini(maxi(combo - 1, 0), 10)
	var pitch := pow(2.0, float(step) / 12.0) * _rng.randf_range(0.97, 1.03)
	_play(_pops[_rng.randi_range(0, _pops.size() - 1)], pitch, -2.0)

func place() -> void:
	_play(_place, _rng.randf_range(0.97, 1.03))

func demolish() -> void:
	_play(_demolish, _rng.randf_range(0.97, 1.03))

func set_muted(on: bool) -> void:
	muted = on

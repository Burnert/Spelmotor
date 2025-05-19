package game

Buffer_Block :: struct($Buf: typeid) {
	next: ^Buffer_Block(Buf),
	data: Buf,
}

Transform :: struct #align(16) {
	translation: [4]f32, // in meters (w is ignored)
	rotation: [4]f32,    // angle in degrees - x:pitch, y:roll, z:yaw (w is ignored)
	scale: [4]f32,       // (w is ignored)
}

make_transform :: proc(t: Vec3 = {0,0,0}, r: Vec3 = {0,0,0}, s: Vec3 = {1,1,1}) -> (transform: Transform) {
	transform.translation.xyz = t
	transform.rotation.xyz = r
	transform.scale.xyz = s
	return
}

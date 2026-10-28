--[[
	CombatAnimations  (ModuleScript)
	Ubicación: ReplicatedStorage > CombatSystem > CombatAnimations

	IDs de animación del combate. CombatConfig los lee de aquí (un valor vacío "" = sin animación / usa el de CombatConfig).
	Pegá acá tus IDs: cuando actualice CombatConfig no se van a pisar.

	Formato: "rbxassetid://NÚMERO".
	Las animaciones se publican SIN "Looped" o no; da igual: CombatService fuerza Looped = false.
]]

return {
	M1_1 = "rbxassetid://90839212634698",
	M1_2 = "rbxassetid://96792142603053",
	M1_3 = "",
	M1_4 = "",
	Uppercut = "",
	AirSlam = "",
	CounterM1 = "",
	RunAttack = "",
	AirGrab = "",
	DummyM1 = "rbxassetid://90839212634698", -- golpe suelto del BasicAttackerDummy (repite el de M1_1)
	Heavy = "",
	Stun = "",
}

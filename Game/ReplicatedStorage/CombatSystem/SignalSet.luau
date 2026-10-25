--[[
	SignalSet  (ModuleScript)
	Ubicación: ReplicatedStorage > Combat > SignalSet

	Conjunto de señales con nombre, basado en BindableEvent.
	Uso:
		local signals = SignalSet.new({ "Hola", "Chau" })
		signals.Events.Hola:Connect(function(...) end)
		signals:Fire("Hola", 1, 2)
		signals:Destroy()

	Nota: los BindableEvent copian las tablas que reciben (no pasan la referencia).
]]

local SignalSet = {}
SignalSet.__index = SignalSet

function SignalSet.new(names)
	local self = setmetatable({}, SignalSet)
	self._bindables = {}
	self.Events = {}

	for _, name in names do
		local bindable = Instance.new("BindableEvent")
		self._bindables[name] = bindable
		self.Events[name] = bindable.Event
	end

	return self
end

function SignalSet:Fire(name, ...)
	local bindable = self._bindables[name]
	if bindable then
		bindable:Fire(...)
	else
		warn("[SignalSet] Señal desconocida: " .. tostring(name))
	end
end

function SignalSet:Destroy()
	for _, bindable in self._bindables do
		bindable:Destroy()
	end
	table.clear(self._bindables)
end

return SignalSet
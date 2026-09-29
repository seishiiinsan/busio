.PHONY: project open test proto

# Génère Busio.xcodeproj depuis project.yml
project:
	@command -v xcodegen >/dev/null || { echo "Installe XcodeGen : brew install xcodegen"; exit 1; }
	xcodegen generate

open: project
	open Busio.xcodeproj

# Tests du moteur (horaires, Zenbus, GTFS)
test:
	cd BusioKit && swift test

# Régénère le code Swift du protocole Zenbus (brew install protobuf swift-protobuf)
proto:
	protoc --swift_opt=Visibility=Public --swift_out=BusioKit/Sources/BusioKit/Zenbus/Generated -IBusioKit/Proto BusioKit/Proto/zenbus.proto

platform "echo-clock"
	requires {
		main! : U64 => {}
	}
	exposes [Host]
	packages {}
	provides { "roc_main": main_for_host! }
	hosted {
		"roc_echo": Host.echo!,
		"roc_now": Host.now!,
	}
	targets: {
		inputs_dir: "targets/",
		arm64mac: { inputs: ["host.o", "mimalloc.o", app] },
		x64mac: { inputs: ["host.o", "mimalloc.o", app] },
	}

import Host

main_for_host! : U64 => {}
main_for_host! = main!

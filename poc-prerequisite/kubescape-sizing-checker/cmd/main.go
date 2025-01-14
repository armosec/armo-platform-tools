package main

type Options struct {
	Enabled bool
}

func Run(opts Options) {
	runSizingChecker()
}

func main() {
	opts := Options{
		Enabled: true,
	}
	Run(opts)
}

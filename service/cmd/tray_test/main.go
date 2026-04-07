package main

import (
	"log"
	"os"

	"fyne.io/systray"
)

func main() {
	f, _ := os.OpenFile("tray_bare.log", os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0666)
	log.SetOutput(f)
	log.Println("bare retest")
	systray.Run(func() {
		log.Println("onReady - OK")
		systray.Quit()
	}, func() {
		log.Println("onExit")
	})
	log.Println("done")
}

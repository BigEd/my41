//
//  CalculatorWindow.swift
//  my41
//
//  Created by Miroslav Perovic on 8/28/14.
//  Copyright (c) 2014 iPera. All rights reserved.
//

import Foundation
import Cocoa

typealias DisplaySegmentMap = UInt32
typealias DisplayFont = [DisplaySegmentMap]
typealias DisplaySegmentPaths = [NSBezierPath]

class CalculatorWindowController: NSWindowController {
	
}

class CalculatorWindow : NSWindow {
	//This point is used in dragging to mark the initial click location
	var initialLocation: NSPoint?
	
	override init(contentRect: NSRect, styleMask aStyle: Int, backing bufferingType: NSBackingStoreType, defer flag: Bool) {
		super.init(contentRect: contentRect, styleMask: aStyle, backing: bufferingType, defer: flag)
	}
	
	required init?(coder: NSCoder) {
		super.init(coder: coder)
	}
	
	override var acceptsFirstResponder: Bool { return true }

	override func awakeFromNib() {
		var appDelegate =  CalculatorApplication.sharedApplication().delegate as AppDelegate
		appDelegate.window = self
		
		self.excludedFromWindowsMenu = false
		self.backgroundColor = NSColor.clearColor()
		self.opaque = false
		self.hasShadow = true
	}
	
	override var canBecomeMainWindow: Bool {
		get {
			return true
		}
	}
	
	override var canBecomeKeyWindow: Bool {
		get {
			return true
		}
	}
	
	override func mouseDown(theEvent: NSEvent) {
		initialLocation = theEvent.locationInWindow
	}
	
	override func mouseDragged(theEvent: NSEvent) {
		let appDelegate = NSApplication.sharedApplication().delegate as AppDelegate
		if appDelegate.buttonPressed {
			return
		}

		if let iLocation = initialLocation {
			let screenVisibleFrame = NSScreen.mainScreen()?.visibleFrame
			let windowFrame = self.frame
			var newOrigin = windowFrame.origin
			
			// Get the mouse location in window coordinates.
			let currentLocation = theEvent.locationInWindow
			
			// Update the origin with the difference between the new mouse location and the old mouse location.
			newOrigin.x += (currentLocation.x - iLocation.x)
			newOrigin.y += (currentLocation.y - iLocation.y)
			
			// Don't let window get dragged up under the menu bar
			if ((newOrigin.y + windowFrame.size.height) > (screenVisibleFrame!.origin.y + screenVisibleFrame!.size.height)) {
				newOrigin.y = screenVisibleFrame!.origin.y + (screenVisibleFrame!.size.height - windowFrame.size.height)
			}
			
			// Move the window to the new location
			self.setFrameOrigin(newOrigin)
		}
	}
	
	override func mouseUp(theEvent: NSEvent) {
		initialLocation = nil
	}
}

typealias Digits12 = [Digit]

let emptyDigit12:[Digit] = [Digit](count: 12, repeatedValue: 0)

struct DisplayRegisters {
	var A: Digits12 = emptyDigit12
	var B: Digits12 = emptyDigit12
	var C: Digits12 = emptyDigit12
	var E: Bits12 = 0
}

let annunciatorStrings: [String] = ["BAT  ", "USER  ", "G", "RAD  ", "SHIFT  ", "0", "1", "2", "3", "4  ", "PRGM  ", "ALPHA"]
let CTULookupRsrcName = "display"
let CTULookupRsrcType = "lookup"
var CTULookup: String?					// lookup table hardware character index -> unichar
var CTULookupLength: Int?				// actual lookup table length (file size)

class Display : NSView, Peripheral {
	let numDisplayCells = 12
	let numAnnunciators = 12
	
	let numDisplaySegments = 17
	let numFontChars = 128
	
	var on: Bool = true
	var updateCountdown: Int = 0
	var registers = DisplayRegisters()
	var displayFont: DisplayFont = DisplayFont()
	var segmentPaths: DisplaySegmentPaths = DisplaySegmentPaths()
	var annunciatorFont: NSFont?
	var annunciatorFontScale: CGFloat = 2.0
	var annunciatorFontSize: CGFloat = 9.0
	var annunciatorBottomMargin: CGFloat = 2.0
	var annunciatorPositions: [NSPoint] = [NSPoint](count: 12, repeatedValue: CGPointMake(0.0, 0.0))
	var foregroundColor: NSColor?
	var aBus: Bus?
	
	var contrast: Digit {
		set {
			self.contrast = newValue & 0xf
			
			scheduleUpdate()
		}
		
		get {
			return self.contrast
		}
	}
	
	let punctSegmentTable: [DisplaySegmentMap] = [
		0x00000, // no punctuation
		0x08000, // .
		0x0C000, // :
		0x18000, // ,
		0x1C000  // ;  (only used during startup segment test)
	]

	enum DisplayShiftDirection {
		case Left
		case Right
	}
	
	enum DisplayTransitionSize {
		case Short
		case Long
	}
	
	enum DisplayRegisterSet : Int {
		case RA = 1
		case RB = 2
		case RC = 4
		case RAB = 3
		case RABC = 7
	}
	
	override init() {
		
		super.init()
	}
	
	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
	}
	
	override func awakeFromNib() {
		calculatorController.display = self
		self.foregroundColor = NSColorList(name: "HP41").colorWithKey("displayForegroundColor")
		self.displayFont = self.loadFont("hpfont")
		self.segmentPaths = self.loadSegmentPaths("hpchar")
		self.annunciatorFont = NSFont(name: "Helvetica", size:self.annunciatorFontScale * self.annunciatorFontSize)
		self.annunciatorPositions = self.calculateAnnunciatorPositions(self.annunciatorFont!, inRect: self.bounds)
		self.on = true
		self.updateCountdown = 2
		bus.installPeripheral(self, inSlot: 0xFD)
		bus.display = self
		
		for idx in 0..<self.numDisplayCells {
			self.registers.A[idx] = 0xA
			self.registers.B[idx] = 0x3
			self.registers.C[idx] = 0x2
			self.registers.E = 0xfff
		}
		
		//-- initialize the display character to unicode lookup table:
		// The table simply contains one unicode character for each X-41 hardware character
		// index (0x00..0x7f). The file can be tweaked for whatever translation is desired.
		// Character groups (approximated):
		// 0x00..0x1f: A-Z uppercase characters
		// 0x20..0x3f: ASCII-like symbols and numbers
		// 0x40..0x4f: a-e + "hangman"
		// 0x50..0x5f: some greek characters + "hangman"
		// 0x60..0x7f: a-z lowercase characters
		let filename: String = NSBundle.mainBundle().pathForResource(CTULookupRsrcName, ofType: CTULookupRsrcType)!
		let mString: NSMutableString = NSMutableString(contentsOfFile: filename, encoding: NSUnicodeStringEncoding, error: nil)!
		CTULookup = String(mString)
		CTULookupLength = countElements(CTULookup!)
	}

	override var flipped:Bool{
		return true
	}
	
	override func drawRect(dirtyRect: NSRect) {
		if on {
			var cellTranslation = NSAffineTransform()
			cellTranslation.translateXBy(cellWidth(), yBy: 0.0)
			foregroundColor?.set()
			if true {
				NSGraphicsContext.saveGraphicsState()
				for idx in 0..<numDisplayCells {
					let segmentsOn = segmentsForCell(idx)
					for seg in 0..<numDisplaySegments {
						if (segmentsOn & (1 << UInt32(seg))) != 0 {
							segmentPaths[seg].fill()
						}
					}
					cellTranslation.concat()
				}
				NSGraphicsContext.restoreGraphicsState()
			}
			
			self.lockFocus()
			let attrs: NSDictionary = NSDictionary(object: annunciatorFont!, forKey: NSFontAttributeName)
			calculatorController.prgmMode = false
			calculatorController.alphaMode = false
			for idx in 0..<numAnnunciators {
				if annunciatorOn(idx) {
					if idx == 10 {
						calculatorController.prgmMode = true
					}
					if idx == 11 {
						calculatorController.alphaMode = true
					}
					
					var transformation = NSAffineTransform()
					let point = annunciatorPositions[idx]
					transformation.translateXBy(point.x, yBy: point.y)
					transformation.scaleBy(1.0 / annunciatorFontScale)
					NSGraphicsContext.saveGraphicsState()
					transformation.concat()
					let nsString = annunciatorStrings[idx] as NSString
					nsString.drawAtPoint(NSMakePoint(0.0, 0.0), withAttributes: attrs)
					NSGraphicsContext.restoreGraphicsState()
				}
			}
			self.unlockFocus()
		}
	}
	
	func cellWidth() -> CGFloat {
		return self.bounds.size.width / CGFloat(numDisplayCells)
	}
	
	override func acceptsFirstMouse(theEvent: NSEvent) -> Bool {
		return true
	}
	
	// Read the current content of the display as an String:
	// Reads the actual hardware registers and converts the content to a normalized
	// unicode string (suppressing leading and trailing spaces).
	func readDisplayAsText() -> String {
		// access the hardware display registers A, B, C:
		let r  = registers
		
		// we need up to two characters per display cell (character+punctuation):
		var text: String = ""
		
		// prepare the punctuation lookup table (8 characters for 3 bit punctuation code)
		let punct: String = " .:,;???"
		
		// loop through the display cells and translate their content:
		var idx: Int			// cell index (decreasing from left to right)

		for idx in reverse(0...numDisplayCells-1) {
			// assemble the actual hardware character index from the register bits:
			// charCode = C0 B1 B0  A3 A2 A1 A0
			let charCode = ((r.C[idx] & 0x1) << 6) | ((r.B[idx] & 0x3) << 4) | (r.A[idx] & 0xf)
			
			// if valid, look up unicode for X-41 hardware character index:
			if charCode < UInt8(CTULookupLength!) {
				// translate:
				let aChar: Character = CTULookup![Int(charCode)]
				let scalars = String(aChar).unicodeScalars

				// only if we already have some valid characters or if this one is valid:
				if scalars[scalars.startIndex].value != 0x20 {
					// not a leading space: save
					text.append(aChar)
				}
			}
			
			let punctCode = ((r.C[idx] & 0x2) << 1) | ((r.B[idx] & 0xc) >> 2)
			
			// if there is any punctuation, insert the respective character from the table:
			if punctCode != 0 {
				text.append(punct[Int(punctCode)])
			}
		}
		
		// now return the completed string as an NSString without any trailing spaces:
		return text
	}
	
	func calculateAnnunciatorPositions(font: NSFont, inRect bounds: NSRect) -> [NSPoint] {
		// Distribute the annunciators evenly across the width of the display based on the sizes of their strings.
		var positions: [NSPoint] = [NSPoint](count: numAnnunciators, repeatedValue: CGPointMake(0.0, 0.0))
		var annunciatorWidths: [CGFloat] = [CGFloat](count: numAnnunciators, repeatedValue: 0.0)
		var spaceWidth: CGFloat = 0.0
		var x: CGFloat = 0.0
		var y: CGFloat = 0.0
		var d: CGFloat = 0.0
		var h: CGFloat = 0.0
		var totalWidth: CGFloat = 0.0
		for idx in 0..<numAnnunciators {
			let nsString: NSString = annunciatorStrings[idx] as NSString
			let width = nsString.sizeWithAttributes(nil).width
			annunciatorWidths[idx] = width
			totalWidth += width
		}
		spaceWidth = (bounds.size.width - totalWidth) / CGFloat(numAnnunciators - 1)
		d -= font.descender
		
		let layoutManager = NSLayoutManager()
		h = layoutManager.defaultLineHeightForFont(font)
		y = bounds.size.height - annunciatorBottomMargin - (h - d) / annunciatorFontScale
		
		for idx in 0..<numAnnunciators {
			positions[idx] = NSMakePoint(x, y)
			x += annunciatorWidths[idx] + spaceWidth
		}
		
		return positions
	}
	
	func displayToggle() {
		// Toggle the display between on and off.
		on = !on
		scheduleUpdate()
	}
	
	func scheduleUpdate() {
		updateCountdown = 2
	}
	
	func displayOff() {
		if on {
			on = false
			scheduleUpdate()
		}
	}
	
	func timeSlice(timer: NSTimer) {
		if (updateCountdown > 0) {
			if (--updateCountdown == 0) {
				setNeedsDisplayInRect(self.bounds)
			}
		}
	}
	
	
	//MARK: - Peripheral Protocol Method
	
	func pluggedIntoBus(theBus: Bus?) {
		self.aBus = theBus
	}
	
	func readFromRegister(param: Bits4) {
		// Implement READ f or READ DATA instruction with display as selected peripheral.
		switch param {
		case 0x0:	//FLLDA
			fetch(&registers, withDirection: .Left, andSize: .Long, withRegister: .RA, andData: &cpu.reg.C)
		case 0x1:	// FLLDB
			fetch(&registers, withDirection: .Left, andSize: .Long, withRegister: .RB, andData: &cpu.reg.C)
		case 0x2:	// FLLDC
			fetch(&registers, withDirection: .Left, andSize: .Long, withRegister: .RC, andData: &cpu.reg.C)
		case 0x3:	// FLLDAB
			fetch(&registers, withDirection: .Left, andSize: .Long, withRegister: .RAB, andData: &cpu.reg.C)
		case 0x4:	// FLLABC
			fetch(&registers, withDirection: .Left, andSize: .Long, withRegister: .RABC, andData: &cpu.reg.C)
		case 0x5:	// READDEN
			bitsToDigits(bits: Int(registers.E), destination: &cpu.reg.C, start: 0, count: 4)
			return					// doesn't change display
		case 0x6:	// FLSDC
			fetch(&registers, withDirection: .Left, andSize: .Short, withRegister: .RA, andData: &cpu.reg.C)
		case 0x7:	// FRSDA
			fetch(&registers, withDirection: .Right, andSize: .Short, withRegister: .RA, andData: &cpu.reg.C)
		case 0x8:	// FRSDB
			fetch(&registers, withDirection: .Right, andSize: .Short, withRegister: .RB, andData: &cpu.reg.C)
		case 0x9:	// FRSDC
			fetch(&registers, withDirection: .Right, andSize: .Short, withRegister: .RC, andData: &cpu.reg.C)
		case 0xA:	// FLSDA
			fetch(&registers, withDirection: .Left, andSize: .Short, withRegister: .RA, andData: &cpu.reg.C) // Original: .RB
		case 0xB:	// FLSDB
			fetch(&registers, withDirection: .Left, andSize: .Short, withRegister: .RB, andData: &cpu.reg.C)
		case 0xC:	// FRSDAB
			fetch(&registers, withDirection: .Right, andSize: .Short, withRegister: .RAB, andData: &cpu.reg.C)
		case 0xD:	// FLSDAB
			fetch(&registers, withDirection: .Left, andSize: .Short, withRegister: .RAB, andData: &cpu.reg.C)
		case 0xE:	// FRSABC
			fetch(&registers, withDirection: .Right, andSize: .Short, withRegister: .RABC, andData: &cpu.reg.C)
		case 0xF:	// FLSABC
			fetch(&registers, withDirection: .Left, andSize: .Short, withRegister: .RABC, andData: &cpu.reg.C)
		default:
			self.aBus?.abortInstruction("Unimplemented display operation")
		}
		scheduleUpdate()
	}
	
	func writeToRegister(param: Bits4) {
		// Implement WRITE f instruction with display as selected peripheral.
		switch param {
		case 0x0:	// SRLDA
			shift(&registers, withDirection: .Right, andSize: .Long, withRegister: .RA, andData: &cpu.reg.C)
		case 0x1:	// SRLDB
			shift(&registers, withDirection: .Right, andSize: .Long, withRegister: .RB, andData: &cpu.reg.C)
		case 0x2:	// SRLDC
			shift(&registers, withDirection: .Right, andSize: .Long, withRegister: .RC, andData: &cpu.reg.C)
		case 0x3:	// SRLDAB
			shift(&registers, withDirection: .Right, andSize: .Long, withRegister: .RAB, andData: &cpu.reg.C)
		case 0x4:	// SRLABC
			shift(&registers, withDirection: .Right, andSize: .Long, withRegister: .RABC, andData: &cpu.reg.C)
		case 0x5:	// SLLDAB
			shift(&registers, withDirection: .Left, andSize: .Short, withRegister: .RAB, andData: &cpu.reg.C)
		case 0x6:	// SLLABC
			shift(&registers, withDirection: .Left, andSize: .Long, withRegister: .RABC, andData: &cpu.reg.C)
		case 0x7:	// SRSDA
			shift(&registers, withDirection: .Right, andSize: .Short, withRegister: .RA, andData: &cpu.reg.C)
		case 0x8:	// SRSDB
			shift(&registers, withDirection: .Right, andSize: .Short, withRegister: .RB, andData: &cpu.reg.C)
		case 0x9:	// SRSDC
			shift(&registers, withDirection: .Right, andSize: .Short, withRegister: .RC, andData: &cpu.reg.C)
		case 0xA:	// SLSDA
			shift(&registers, withDirection: .Left, andSize: .Short, withRegister: .RA, andData: &cpu.reg.C)
		case 0xB:	// SLSDB
			shift(&registers, withDirection: .Left, andSize: .Short, withRegister: .RB, andData: &cpu.reg.C)
		case 0xC:	// SRSDAB
			shift(&registers, withDirection: .Right, andSize: .Short, withRegister: .RAB, andData: &cpu.reg.C)
		case 0xD:	// SLSDAB
			shift(&registers, withDirection: .Left, andSize: .Short, withRegister: .RAB, andData: &cpu.reg.C)
		case 0xE:	// SRSABC
			shift(&registers, withDirection: .Right, andSize: .Short, withRegister: .RABC, andData: &cpu.reg.C)
		case 0xF:	// SLSABC
			shift(&registers, withDirection: .Left, andSize: .Short, withRegister: .RABC, andData: &cpu.reg.C)
		default:
			self.aBus?.abortInstruction("Unimplemented display operation")
		}
		scheduleUpdate()
	}
	
	func displayWrite()
	{
		switch cpu.opcode.row() {
		case 0x0:
			// 028          SRLDA    WRA12L   SRLDA
			registers.A[0] = cpu.reg.C[0]
			registers.A[1] = cpu.reg.C[1]
			registers.A[2] = cpu.reg.C[2]
			registers.A[3] = cpu.reg.C[3]
			registers.A[4] = cpu.reg.C[4]
			registers.A[5] = cpu.reg.C[5]
			registers.A[6] = cpu.reg.C[6]
			registers.A[7] = cpu.reg.C[7]
			registers.A[8] = cpu.reg.C[8]
			registers.A[9] = cpu.reg.C[9]
			registers.A[10] = cpu.reg.C[10]
			registers.A[11] = cpu.reg.C[11]
		case 0x1:
			// 068          SRLDB    WRB12L   SRLDB
			registers.B[0] = cpu.reg.C[0]
			registers.B[1] = cpu.reg.C[1]
			registers.B[2] = cpu.reg.C[2]
			registers.B[3] = cpu.reg.C[3]
			registers.B[4] = cpu.reg.C[4]
			registers.B[5] = cpu.reg.C[5]
			registers.B[6] = cpu.reg.C[6]
			registers.B[7] = cpu.reg.C[7]
			registers.B[8] = cpu.reg.C[8]
			registers.B[9] = cpu.reg.C[9]
			registers.B[10] = cpu.reg.C[10]
			registers.B[11] = cpu.reg.C[11]
		case 0x2:
			// 0A8          SRLDC    WRC12L   SRLDC
			registers.C[0] = cpu.reg.C[0]
			registers.C[1] = cpu.reg.C[1]
			registers.C[2] = cpu.reg.C[2]
			registers.C[3] = cpu.reg.C[3]
			registers.C[4] = cpu.reg.C[4]
			registers.C[5] = cpu.reg.C[5]
			registers.C[6] = cpu.reg.C[6]
			registers.C[7] = cpu.reg.C[7]
			registers.C[8] = cpu.reg.C[8]
			registers.C[9] = cpu.reg.C[9]
			registers.C[10] = cpu.reg.C[10]
			registers.C[11] = cpu.reg.C[11]
		case 0x3:
			// 0E8          SRLDAB   WRAB6L   SRLDAB
			rotateRegisterLeft(&registers.A, times: 6)
			rotateRegisterLeft(&registers.B, times: 6)
			registers.A[6] = cpu.reg.C[0]
			registers.B[6] = cpu.reg.C[1]
			registers.A[7] = cpu.reg.C[2]
			registers.B[7] = cpu.reg.C[3]
			registers.A[8] = cpu.reg.C[4]
			registers.B[8] = cpu.reg.C[5]
			registers.A[9] = cpu.reg.C[6]
			registers.B[9] = cpu.reg.C[7]
			registers.A[10] = cpu.reg.C[8]
			registers.B[10] = cpu.reg.C[9]
			registers.A[11] = cpu.reg.C[10]
			registers.B[11] = cpu.reg.C[11]
		case 0x4:
			// 128          SRLABC   WRABC4L  SRLABC                       ;also HP:SRLDABC
			rotateRegisterLeft(&registers.A, times: 4)
			rotateRegisterLeft(&registers.B, times: 4)
			rotateRegisterLeft(&registers.C, times: 4)
			registers.A[8] = cpu.reg.C[0]
			registers.B[8] = cpu.reg.C[1]
			registers.C[8] = cpu.reg.C[2] & 0x01
			registers.A[9] = cpu.reg.C[3]
			registers.B[9] = cpu.reg.C[4]
			registers.C[9] = cpu.reg.C[5] & 0x01
			registers.A[10] = cpu.reg.C[6]
			registers.B[10] = cpu.reg.C[7]
			registers.C[10] = cpu.reg.C[8] & 0x01
			registers.A[11] = cpu.reg.C[9]
			registers.B[11] = cpu.reg.C[10]
			registers.C[11] = cpu.reg.C[11] & 0x01
		case 0x5:
			// 168          SLLDAB   WRAB6R   SLLDAB
			rotateRegisterRight(&registers.A, times: 6)
			rotateRegisterRight(&registers.B, times: 6)
			registers.A[5] = cpu.reg.C[0]
			registers.B[5] = cpu.reg.C[1]
			registers.A[4] = cpu.reg.C[2]
			registers.B[4] = cpu.reg.C[3]
			registers.A[3] = cpu.reg.C[4]
			registers.B[3] = cpu.reg.C[5]
			registers.A[2] = cpu.reg.C[6]
			registers.B[1] = cpu.reg.C[7]
			registers.A[1] = cpu.reg.C[8]
			registers.B[1] = cpu.reg.C[9]
			registers.A[0] = cpu.reg.C[10]
			registers.B[0] = cpu.reg.C[11]
		case 0x6:
			// 1A8          SLLABC   WRABC4R  SLLABC                       ;also HP:SLLDABC
			rotateRegisterRight(&registers.A, times: 4)
			rotateRegisterRight(&registers.B, times: 4)
			rotateRegisterRight(&registers.C, times: 4)
			registers.A[3] = cpu.reg.C[0]
			registers.B[3] = cpu.reg.C[1]
			registers.C[3] = cpu.reg.C[2] & 0x01
			registers.A[2] = cpu.reg.C[3]
			registers.B[2] = cpu.reg.C[4]
			registers.C[2] = cpu.reg.C[5] & 0x01
			registers.A[1] = cpu.reg.C[6]
			registers.B[1] = cpu.reg.C[7]
			registers.C[1] = cpu.reg.C[8] & 0x01
			registers.A[0] = cpu.reg.C[9]
			registers.B[0] = cpu.reg.C[10]
			registers.C[0] = cpu.reg.C[11] & 0x01
		case 0x7:
			// 1E8          SRSDA    WRA1L    SRSDA
			rotateRegisterLeft(&registers.A, times: 1)
			registers.A[11] = cpu.reg.C[0]
		case 0x8:
			// 228          SRSDB    WRB1L    SRSDB
			rotateRegisterLeft(&registers.B, times: 1)
			registers.B[11] = cpu.reg.C[0]
		case 0x9:
			// 268          SRSDC    WRC1L    SRSDC
			rotateRegisterLeft(&registers.C, times: 1)
			registers.C[11] = cpu.reg.C[0] & 0x01
		case 0xa:
			// 2A8          SLSDA    WRA1R    SLSDA
			rotateRegisterRight(&registers.A, times: 1)
			registers.A[0] = cpu.reg.C[0]
		case 0xb:
			// 2E8          SLSDB    WRB1R    SLSDB
			rotateRegisterRight(&registers.B, times: 1)
			registers.B[0] = cpu.reg.C[0]
		case 0xc:
			// 328          SRSDAB   WRAB1L   SRSDAB                        ;Zenrom manual incorrectly says this is WRC1R
			rotateRegisterLeft(&registers.A, times: 1)
			rotateRegisterLeft(&registers.B, times: 1)
			registers.A[11] = cpu.reg.C[0]
			registers.B[11] = cpu.reg.C[1]
		case 0xd:
			// 368          SLSDAB   WRAB1R   SLSDAB
			rotateRegisterRight(&registers.A, times: 1)
			rotateRegisterRight(&registers.B, times: 1)
			registers.A[0] = cpu.reg.C[0]
			registers.B[0] = cpu.reg.C[1]
		case 0xe:
			// 3A8          SRSABC   WRABC1L  SRSABC                        ;also HP:SRSDABC
			rotateRegisterLeft(&registers.A, times: 1)
			rotateRegisterLeft(&registers.B, times: 1)
			rotateRegisterLeft(&registers.C, times: 1)
			registers.A[11] = cpu.reg.C[0]
			registers.B[11] = cpu.reg.C[1]
			registers.C[11] = cpu.reg.C[2] & 0x01
		case 0xf:
			// 3E8          SLSABC   WRABC1R  SLSABC                        ;also HP:SLSDABC
			rotateRegisterRight(&registers.A, times: 1)
			rotateRegisterRight(&registers.B, times: 1)
			rotateRegisterRight(&registers.C, times: 1)
			registers.A[0] = cpu.reg.C[0]
			registers.B[0] = cpu.reg.C[1]
			registers.C[0] = cpu.reg.C[2] & 0x01
		default:
			break
		}
		
		scheduleUpdate()
	}
	
	func writeDataFrom(data: Digits14)
	{
		// Implement WRITE DATA instruction with display as selected peripheral.
		registers.E = digitsToBits(digits: data, nbits: 12)
		scheduleUpdate()
	}
	
	
	//MARK: -
	func fetch(
		inout registers: DisplayRegisters,
		withDirection direction:DisplayShiftDirection,
		andSize size:DisplayTransitionSize,
		withRegister regset:DisplayRegisterSet,
		inout andData data: Digits14
		)
	{
		/*
			Fetch digits from the specified registers, rotating them in the specified direction,
			and assemble them into the specified destination.
			For size == LONG, fetches a total of 12 digits into the destination;
			for size == SHORT, fetches one digit from each specified register.
		*/
		var cp = 0
		while cp < 12 {
			if (regset.rawValue & DisplayRegisterSet.RA.rawValue) != 0 {
				fetchDigit(direction, from: &registers.A, to: &data[cp++])
			}
			if (regset.rawValue & DisplayRegisterSet.RB.rawValue) != 0 {
				fetchDigit(direction, from: &registers.B, to: &data[cp++])
			}
			if (regset.rawValue & DisplayRegisterSet.RC.rawValue) != 0 {
				fetchDigit(direction, from: &registers.C, to: &data[cp++])
			}
			if size == .Short {
				break
			}
		}
	}
	
	func fetchDigit(
		direction: DisplayShiftDirection,
		inout from register: Digits12,
		inout to dst: Digit
		) -> Digits12
	{
		/*
			Fetch a digit from the appropriate end of the given register into the specified destination,
			and rotate the register in the specified direction.
		*/
		switch direction {
		case .Left:
			dst = register[11]
			rotateRegisterLeft(&register)
		case .Right:
			dst = register[0]
			rotateRegisterRight(&register)
		}
		
		return register
	}
	
	func rotateRegisterLeft(inout register: Digits12)
	{
		let temp = register[11]
		for idx in reverse(1...11) {
			register[idx] = register[idx - 1]
		}
		register[0] = temp
	}
	
	func rotateRegisterRight(inout register: Digits12, times: Int)
	{
		if times > 0 {
			for pass in 0..<times {
				let temp = register[11]
				for idx in reverse(1...11) {
					register[idx] = register[idx - 1]
				}
				register[0] = temp
			}
		}
	}
	
	func rotateRegisterRight(inout register: Digits12) {
		let temp = register[0]
		for idx in 0...10 {
			register[idx] = register[idx + 1]
		}
		register[11] = temp
	}
	
	func rotateRegisterLeft(inout register: Digits12, times: Int) {
		if times > 0 {
			for pass in 0..<times {
				let temp = register[0]
				for idx in 0...10 {
					register[idx] = register[idx + 1]
				}
				register[11] = temp
			}
		}
	}
	
	func shift(
		inout registers: DisplayRegisters,
		withDirection direction:DisplayShiftDirection,
		andSize size:DisplayTransitionSize,
		withRegister regset:DisplayRegisterSet,
		inout andData data: Digits14
		)
	{
		/*
			Distribute digits from the given source and rotate them into the specified registers.
			For size == LONG, shifts a total of 12 digits from the source;
			for size == SHORT, shifts one digit into each specified register.
		*/
		var cp = 0
		while cp < 12 {
			if (regset.rawValue & DisplayRegisterSet.RA.rawValue) != 0 {
				shiftDigit(direction, from: &registers.A, withFilter: data[cp++])
			}
			if (regset.rawValue & DisplayRegisterSet.RB.rawValue) != 0 {
				shiftDigit(direction, from: &registers.B, withFilter: data[cp++])
			}
			if (regset.rawValue & DisplayRegisterSet.RC.rawValue) != 0 {
				shiftDigit(direction, from: &registers.C, withFilter: data[cp++])
			}
			if size == .Short {
				break
			}
		}
	}
	
	func shiftDigit(direction: DisplayShiftDirection, inout from register: Digits12, withFilter src: Digit) {
		// Rotate the given digit into the specified register in the specified direction.
		switch direction {
		case .Left:
			rotateRegisterLeft(&register)
			register[0] = src
		case .Right:
			rotateRegisterRight(&register)
			register[11] = src
		}
	}
	
	func segmentsForCell(i: Int) -> DisplaySegmentMap {
		/*
			Determine which segments should be on for cell i based on the contents of the display registers.
			Note that cells are numbered from left to right, which is the opposite of the digit numbering in the display registers.
		*/
		let j = 11 - i
		let nineBitCode: Int = Int((Int(registers.C[j]) << 8) | (Int(registers.B[j]) << 4) | (Int(registers.A[j]))) & 0x1ff
		let charCode: Int = ((nineBitCode & 0x100) >> 2) | (nineBitCode & 0x3f)
		let punctCode = Int((Int(registers.C[j]) & 0x2) << 1) | (nineBitCode & 0xc0) >> 6

		return displayFont[Int(charCode)] | punctSegmentTable[Int(punctCode)]
	}
	
	func annunciatorOn(i: Int) -> Bool {
		/*
			Determine whether annunciator number i should be on based on the contents of the E register.
			Note that i is not the same as the bit number in E, because the annunciators are numbered from left to right.
		*/
		let j: Bits12 = 11 - Bits12(i)
		
		return (registers.E & (1 << j)) != 0
	}
	
	
	//MARK: - Font support
	
	func loadFont(resourceName: String) -> DisplayFont {
		var font: DisplayFont = DisplayFont(count:128, repeatedValue: 0)
		let filename = NSBundle.mainBundle().pathForResource(resourceName, ofType: "hpfont")
		var data = NSData(contentsOfFile: filename!, options: .DataReadingMappedIfSafe, error: nil)
		var range = NSRange(location: 0, length: 4)
		for idx in 0..<127 {
			var tmp: UInt32 = 0
			var tmp2: UInt32 = 0
			data?.getBytes(&tmp, range: range)
			range.location += 4
			tmp2 = UInt32(bigEndian: tmp)
			
			font[idx] = tmp2
		}
		
		return font
	}
	
	func loadSegmentPaths(file: String) -> DisplaySegmentPaths {
		var paths: DisplaySegmentPaths = DisplaySegmentPaths()
		let path = NSBundle.mainBundle().pathForResource(file, ofType: "geom")
		var data = NSData(contentsOfFile: path!, options: .DataReadingMappedIfSafe, error: nil)
		var unarchiver = NSKeyedUnarchiver(forReadingWithData: data!)
		let dict = unarchiver.decodeObjectForKey("bezierPaths") as NSDictionary
		unarchiver.finishDecoding()
		for idx in 0..<numDisplaySegments {
			let key = String(idx)
			let path = dict[key]! as NSBezierPath
			paths.append(path)
		}
		
		return paths
	}
	
	func digits12ToString(register: Digits12) -> String {
		var result = String()
		for idx in reverse(0...11) {
			result += NSString(format:"%1X", register[idx])
		}
		
		return result
	}
	
	//MARK: - Halfnut
	func halfnutWrite()
	{
		// REG=C 5
		if cpu.opcode.row() == 5 {
			contrast = cpu.reg.C[0]
		}
	}
	
	func halfnutRead()
	{
		if cpu.opcode.row() == 5 {
			cpu.reg.C[0] = contrast
		}
	}
}
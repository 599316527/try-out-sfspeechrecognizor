//
//  ViewController.swift
//  SpeechRecognizorTest
//
//  Created by Kyle He on 2019/6/11.
//  Copyright © 2019 hekai. All rights reserved.
//

import UIKit
import Speech

import Foundation
// 导入CommonCrypto
import CommonCrypto

// 直接给String扩展方法
extension String {
    func md5() -> String {
        let str = self.cString(using: String.Encoding.utf8)
        let strLen = CUnsignedInt(self.lengthOfBytes(using: String.Encoding.utf8))
        let digestLen = Int(CC_MD5_DIGEST_LENGTH)
        let result = UnsafeMutablePointer<UInt8>.allocate(capacity: 16)
        CC_MD5(str!, strLen, result)
        let hash = NSMutableString()
        for i in 0 ..< digestLen {
            hash.appendFormat("%02x", result[i])
        }
        free(result)
        return String(format: hash as String)
    }
}

struct CustomSegment: Encodable {
    var substringRange: NSRange
    var confidence: Float
    var timestamp: TimeInterval
    var duration: TimeInterval
}

struct ResultFormat: Encodable {
    var result: String
    var segments: [CustomSegment]
}

class ViewController: UIViewController, SFSpeechRecognizerDelegate {
    @IBOutlet weak var urlInputField: UITextField!
    @IBOutlet weak var statusLabel: UILabel!
    @IBOutlet weak var progressBar: UIProgressView!
    @IBOutlet weak var resultTextView: UITextView!
    @IBOutlet weak var segmentTextView: UITextView!
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))!
    private var recognitionRequest: SFSpeechURLRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        urlInputField.text = ""
        progressBar.progress = 0
    }
    
    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        speechRecognizer.delegate = self
        
        SFSpeechRecognizer.requestAuthorization { authStatus in
            OperationQueue.main.addOperation {
                switch authStatus {
                    case .authorized:
                        self.statusLabel.text = "Authorized"
                    
                    case .denied:
                        self.statusLabel.text = "Denied"
                    
                    case .restricted:
                        self.statusLabel.text = "Restricted"
                    
                    case .notDetermined:
                        self.statusLabel.text = "Unauthorized"
                    
                    default:
                        self.statusLabel.text = "Unknown"
                }
            }
        }
    }

    @IBAction func handleConfirmButtonTap(_ sender: UIButton) {
        downloadFile(url: urlInputField.text!, callback: startRecognize)
    }
    
    private func downloadFile(url: String, callback: @escaping (URL) -> Void) -> Void {
        let md5 = url.md5()
        
        var documentsURL: URL!
        do {
            documentsURL = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        } catch {
            print ("file error: \(error)")
        }
        
        let sourceURL = URL(string: url)!
        let savedURL = documentsURL.appendingPathComponent(md5).appendingPathExtension(sourceURL.pathExtension);
        
        if FileManager.default.fileExists(atPath: savedURL.path) {
            callback(savedURL)
            return
        }
        
        print("Download %@", url)
        let downloadTask = URLSession.shared.downloadTask(with: sourceURL) { urlOrNil, responseOrNil, errorOrNil in
            guard let fileURL = urlOrNil else { return }
            do {
                try FileManager.default.moveItem(at: fileURL, to: savedURL)
            } catch {
                print ("file error: \(error)")
            }
            print("Downloaded %@", savedURL)
            callback(savedURL)
        }
        downloadTask.resume()
    }
    
    private func startRecognize(url: URL) -> Void {
        recognitionTask?.cancel()
        self.recognitionTask = nil
        
        // Create and configure the speech recognition request.
        recognitionRequest = SFSpeechURLRecognitionRequest(url: url)
        guard let recognitionRequest = recognitionRequest else { fatalError("Unable to create a SFSpeechAudioBufferRecognitionRequest object") }
        recognitionRequest.shouldReportPartialResults = true
        
        func finishCallback(value: Any) {
            let transcription: SFTranscription = value as! SFTranscription
            var segments: [CustomSegment] = []
            for item in transcription.segments {
                let segment = CustomSegment(
                    substringRange: item.substringRange,
                    confidence: item.confidence,
                    timestamp: item.timestamp,
                    duration: item.duration
                )
                segments.append(segment)
            }
            
            let result = ResultFormat(result: transcription.formattedString, segments: segments)
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            do {
                let data = try encoder.encode(result)
                self.segmentTextView.text = String(data: data, encoding: .utf8)
            } catch {
                print("format final result error")
            }
            
        }
        // 非常蛋疼，recognitionRequest 的 result.isFinal 一直都是 false，明明已经停止识别了还是 false，等着等着就超时了。
        // 查到有人说不要信 isFinal https://stackoverflow.com/a/45258990
        // 只能搞个 debounce，认为 5 秒没输出就停了
        let finishRecognize = Debouncer(delay: 5, callback: finishCallback);
        
        // Create a recognition task for the speech recognition session.
        // Keep a reference to the task so that it can be canceled.
        print("Start recognize")
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { result, error in
            var isFinal = false

            if let result = result {
                isFinal = result.isFinal
                self.resultTextView.text = result.bestTranscription.formattedString
                print(result.bestTranscription.segments.count)
                finishRecognize.call(value: result.bestTranscription)
            }

            if error != nil || isFinal {
                self.recognitionRequest = nil
                self.recognitionTask = nil
            }
        }
        
    }
    
}


class Debouncer: NSObject {
    var callback: ((_ value: Any) -> ())
    var delay: Double
    weak var timer: Timer?
    var value: Any = 0
    
    init(delay: Double, callback: @escaping ((_ value: Any) -> ())) {
        self.delay = delay
        self.callback = callback
    }
    
    func call(value: Any) {
        self.value = value
        timer?.invalidate()
        let nextTimer = Timer.scheduledTimer(timeInterval: delay, target: self, selector: #selector(Debouncer.fireNow), userInfo: nil, repeats: false)
        timer = nextTimer
    }
    
    @objc func fireNow() {
        self.callback(self.value)
    }
}

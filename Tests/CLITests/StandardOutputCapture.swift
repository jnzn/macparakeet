import Darwin
import Foundation

func captureStandardOutput(_ body: () throws -> Void) throws -> String {
    let pipe = Pipe()
    let originalStdout = dup(STDOUT_FILENO)
    guard originalStdout >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    fflush(stdout)
    guard dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0 else {
        close(originalStdout)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    var bodyError: Error?
    do {
        try body()
    } catch {
        bodyError = error
    }

    fflush(stdout)
    dup2(originalStdout, STDOUT_FILENO)
    close(originalStdout)
    pipe.fileHandleForWriting.closeFile()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    if let bodyError {
        throw bodyError
    }
    return String(decoding: data, as: UTF8.self)
}

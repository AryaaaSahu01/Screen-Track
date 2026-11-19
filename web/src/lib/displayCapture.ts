export function stopDisplayCapture(stream: MediaStream | null ): void {
    stream?.getTracks().forEach((track) => track.stop())
}


export async function requestDisplayCapture(): Promise<MediaStream> {
    if (!window.isSecureContext) {
        throw new Error('Open this app on localhost or HTTPs to choose a screen.')
    }
    if (!navigator.mediaDevices?.getDisplayMedia) {
        throw new Error('Screen capture is unavailable. Try desktop Chrome or Edge. ')
    }

    const stream = await navigator.mediaDevices.getDisplayMedia({
        video: true,
        audio: false,
    })

    if (stream.getVideoTracks().length === 0 ) {
        stopDisplayCapture(stream)
        throw new Error('The selected source did not provide a video track. ')
    }
    return stream
}

export function captureErrorMessage(error: unknown): string {
    if (error instanceof DOMException) {
        if (error.name === 'NotAllowedError' ) {
            return 'Screen selection was cancelled or denied. You can try again.'
        }

        if (error.name === 'NotReadableError') {
            return 'The source could not be read. Check screen-sharing permissions.'
        }
    }
    return error instanceof Error ? error.message : 'Screen capture could not start. '
}
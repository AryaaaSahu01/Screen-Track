import { useEffect, useRef, useState } from "react"
import {
    captureErrorMessage,
    requestDisplayCapture,
    stopDisplayCapture,
} from '../../lib/displayCapture'

type Phase = 'idle' | 'choosing' | 'previewing'

export function CapturePreview() {
    const [phase, setPhase] = useState<Phase>('idle')
    const [error, setError] = useState<string | null>(null)
    const videoRef = useRef<HTMLVideoElement | null>(null)
    const streamRef = useRef<MediaStream | null>(null)
    const requestVersionRef = useRef(0)

    useEffect(()=>{
        const video = videoRef.current
        return () => {
            requestVersionRef.current += 1
            stopDisplayCapture(streamRef.current)
            streamRef.current = null
            if (video) video.srcObject = null
        }
    }, [])

    function stopPreview() {
        requestVersionRef.current +=1
        const stream = streamRef.current
        streamRef.current = null
        stopDisplayCapture(stream)
        if (videoRef.current) videoRef.current.srcObject = null
        setPhase('idle')
    }

    async function startPreview() {
        if (phase !== 'idle') return
        const version = ++requestVersionRef.current
        setError(null)
        setPhase('choosing')

        try {
            const stream = await requestDisplayCapture()
            if (version !== requestVersionRef.current) {
                stopDisplayCapture(stream)
                return
            }

            const video = videoRef.current
            if (!video) {
                stopDisplayCapture(stream)
                throw new Error('The preview is unavailable. Please try again.')
            }

            streamRef.current = stream
            video.srcObject = stream
            stream.getVideoTracks()[0].addEventListener('ended', () => {
                if (streamRef.current === stream) stopPreview()
            }, { once: true})
            setPhase('previewing')
        } catch (cause) {
            if (version !== requestVersionRef.current) return
            setError(captureErrorMessage(cause))
            setPhase('idle')
        }
    }
    return (
        <section className="panel" aria-labelledby="capture-heading">
            <h2 id="capture-heading">Screen Preview</h2>
            <p>Choose a screen, window or tab. This checkpoint previews it locally.</p>
            <div className="actions">
                <button type="button" onClick={startPreview} disabled={phase !== 'idle'}>
                    {phase === 'choosing' ? 'Choose a source in the browser' : 'Choose a screen'}
                </button>
                <button type = "button" onClick={stopPreview} disabled={phase !== 'previewing'}>
                    Stop Preview
                </button>
            </div>
            <p role = "status"> Preview: {phase}</p>
            {error && <p role="alert">{error}</p>}
            <video ref={videoRef} autoPlay muted playsInline aria-label="Selected screen preview" />
            <p className="muted">Preview only. Saving and timelapse encoding follow in C0B.</p>
        </section>
    )
}


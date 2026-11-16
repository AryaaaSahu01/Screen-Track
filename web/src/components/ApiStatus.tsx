import { useEffect, useState } from "react"

type Status = 'checking' | 'connected' | 'offline'

export function ApiStatus() {
    const [status, setStatus ] = useState<Status>('checking')

    useEffect(() => {
        const controller = new AbortController()

        let active = true

        const timeout = window.setTimeout(() => controller.abort(), 5000)

        async function checkHealth() {
            try {
                const response = await fetch('/health', { signal: controller.signal })
                if (!response.ok) throw new Error('HTTP ${response.status}')
                
                const body: unknown = await response.json()
                if (
                    typeof body !== 'object' || body === null ||
                    !('status' in body) || body.status !== 'ok'
                ) {
                    throw new Error('Unexpected health response')
                }

                if (active) setStatus('connected')
            } catch {
                if (active) setStatus('offline')
            } finally {
                window.clearTimeout(timeout)
            }
        }

        void checkHealth()

        return () => {
            active = false
            window.clearTimeout
            controller.abort()
        }
    },[])

    return <p role="status">API: {status}</p>
}
import { ApiStatus } from "./components/ApiStatus"
import { CapturePreview } from "./features/recorder/CapturePreview"
import './App.css'


function App() {
  return (
    <main className="app">
      <header className="page-header">
        <div>
          <p className="muted">Capture foundation · C0A</p>
          <h1>Track My Screen</h1>
        </div>
        <ApiStatus/>
      </header>
      <CapturePreview/>
    </main>
  )
}

export default App
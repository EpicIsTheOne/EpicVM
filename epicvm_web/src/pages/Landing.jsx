import React, { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import {
  Desktop, Cloud, Cpu, Lock, Lightning, ArrowRight, CheckCircle,
  GameController, WindowsLogo, LinuxLogo, ShieldCheck, WifiHigh, Rocket,
} from '@phosphor-icons/react'

function Nav({ authed, onSignout }) {
  const go = (path) => () => { window.location.assign('/EpicVM' + path) }
  const jump = (id) => (e) => {
    e.preventDefault()
    const el = document.getElementById(id)
    if (el) el.scrollIntoView({ behavior: 'smooth', block: 'start' })
    else window.location.assign('/EpicVM/#' + id)
  }
  return (
    <header className="evm-nav">
      <a className="evm-brand" href="/EpicVM/" onClick={(e) => { e.preventDefault(); window.location.assign('/EpicVM/') }}>
        <span className="evm-brand-mark">EV</span>
        <span>EpicVM</span>
      </a>
      <nav className="evm-nav-links">
        <a href="#features" onClick={jump('features')}>Features</a>
        <a href="#how" onClick={jump('how')}>How It Works</a>
        <a href="#vm-types" onClick={jump('vm-types')}>Access options</a>
        <a href="#faq" onClick={jump('faq')}>FAQ</a>
      </nav>
      <div className="evm-nav-actions">
        <a className="evm-btn evm-btn-ghost" href="/EpicVM/settings">Settings</a>
        {authed ? (
          <>
            <button className="evm-btn evm-btn-ghost" onClick={() => window.location.assign('/EpicVM/pending')}>Account</button>
            <button className="evm-btn evm-btn-primary" onClick={() => window.location.assign('/EpicVM/portal')}>Open Portal</button>
          </>
        ) : (
          <>
            <button className="evm-btn evm-btn-ghost" onClick={go('/signin')}>Sign In</button>
            <button className="evm-btn evm-btn-primary" onClick={go('/signup')}>Request Access</button>
          </>
        )}
      </div>
    </header>
  )
}

const STEPS = [
  { n: 1, title: 'Create an account', body: 'Request access to EpicVM.' },
  { n: 2, title: 'Get approved', body: 'Accounts are manually reviewed before gaining access.' },
  { n: 3, title: 'Get desktop access', body: 'Epic assigns a Windows desktop, games, or a VM to your account.' },
  { n: 4, title: 'Open your desktop', body: 'Sign in, choose Open desktop, and connect in your browser. Resume it when you return.' },
]

const VM_TYPES = [
  { icon: WindowsLogo, label: 'Hosted desktops', tag: 'windows', title: 'Windows desktop', body: 'A personal Windows session on our shared host, with your own account and files. Use apps and play assigned games in your browser.' },
  {
    icon: LinuxLogo, label: 'By request', tag: 'linux', title: 'Linux VM',
    body: 'A personal Linux environment for coding, hosting projects, automation, experimentation, servers, and development. VMs are available by request and assigned separately from hosted desktops.',
  },
  {
    icon: WindowsLogo, label: 'Limited Beta', tag: 'windows', title: 'Windows VM',
    body: 'A full Windows environment for applications and workflows that require Windows. Currently available only to selected testers.',
  },
  {
    icon: GameController, label: 'Experimental', tag: 'gaming', title: 'Gaming VM',
    body: 'GPU-accelerated Windows environments intended for remote gaming and GPU workloads. Availability is extremely limited while performance and capacity are tested.',
  },
]

const FEATURES = [
  { icon: Desktop, title: 'Your Own Workspace', body: 'Your own Windows account and files on a hosted desktop, or a separately assigned VM.' },
  { icon: WifiHigh, title: 'Access Anywhere', body: 'Connect remotely from supported devices.' },
  { icon: Lightning, title: 'Easy to Open', body: 'Your assigned desktops and games appear after you sign in.' },
  { icon: Cpu, title: 'Linux + Windows', body: 'Different machine types for different workflows.' },
  { icon: GameController, title: 'GPU Acceleration', body: 'Available on selected experimental Gaming VMs.' },
  { icon: Rocket, title: 'Built for Experimentation', body: 'Development, hosting, automation, learning, gaming, and personal projects.' },
]

const FAQ = [
  { q: 'Is EpicVM free?', a: 'Yes, during the current beta.' },
  { q: 'What can I use?', a: 'Your workspace shows the Windows desktops, games, and VMs Epic has assigned to your account. Access depends on available host capacity.' },
  { q: 'How do I return to my desktop?', a: 'Sign in and choose Resume desktop. Closing the stream tab leaves your apps running. End session closes apps and signs you out of Windows, so save your work first.' },
  { q: 'Can I get a Gaming VM?', a: 'Gaming VMs are experimental and currently available only to selected testers.' },
  { q: 'Can I store important files on EpicVM?', a: 'During beta, keep backups of important data elsewhere. Do not treat EpicVM as the only copy of critical files.' },
  { q: 'Who can join?', a: 'EpicVM is a beta. Accounts must be approved before gaining access.' },
]

export default function Landing({ authed, onSignout }) {
  const navigate = useNavigate()
  const go = (path) => navigate(path)
  useEffect(() => {
    const els = Array.from(document.querySelectorAll('.evm-landing .evm-section'))
    if (!('IntersectionObserver' in window)) {
      els.forEach((el) => el.classList.add('evm-reveal-in'))
      return
    }
    const io = new IntersectionObserver((entries) => {
      entries.forEach((en) => {
        if (en.isIntersecting) {
          en.target.classList.add('evm-reveal-in')
          io.unobserve(en.target)
        }
      })
    }, { threshold: 0.12, rootMargin: '0px 0px -8% 0px' })
    els.forEach((el) => io.observe(el))
    return () => io.disconnect()
  }, [])
  return (
    <div className="evm-page evm-landing">
      <Nav authed={authed} onSignout={onSignout} />

      {/* Hero */}
      <section className="evm-hero">
        <div className="evm-hero-inner">
          <div className="evm-hero-copy">
            <span className="evm-pill">BETA</span>
            <h1 className="evm-h1">Your PC.<br />Anywhere.</h1>
            <p className="evm-lead">
              Open your hosted Windows desktop and play assigned games from your browser. Sign in, connect, and resume when you return.
            </p>
            <div className="evm-hero-cta">
              <button className="evm-btn evm-btn-primary evm-btn-lg" onClick={() => go('/signup')}>Request Access</button>
              <button className="evm-btn evm-btn-ghost evm-btn-lg" onClick={() => go('/signin')}>Sign In</button>
            </div>
          </div>
          <div className="evm-hero-visual" aria-hidden="true">
            <div className="evm-window">
              <div className="evm-window-bar"><i /><i /><i /></div>
              <div className="evm-window-body">
                <div className="evm-vm-card">
                  <span className="evm-vm-os"><WindowsLogo size={18} /> Personal desktop</span>
                  <span className="evm-vm-state live">Ready</span>
                  <div className="evm-vm-row"><span>CPU</span><div className="evm-bar"><i style={{ width: '34%' }} /></div></div>
                  <div className="evm-vm-row"><span>RAM</span><div className="evm-bar"><i style={{ width: '52%' }} /></div></div>
                  <div className="evm-vm-meta">Windows · Your account and files</div>
                  <button className="evm-btn evm-btn-primary evm-btn-sm">Open desktop</button>
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* What is */}
      <section className="evm-section">
        <h2 className="evm-h2">What is EpicVM?</h2>
        <p className="evm-body">
          EpicVM gives approved friends access to hosted Windows desktops and games. Your desktop uses
          your own Windows account and files on a shared host. Open it from your workspace in the browser.
          Linux and Windows VMs are also available when separately assigned.
        </p>
      </section>

      {/* How it works */}
      <section className="evm-section" id="how">
        <h2 className="evm-h2">How It Works</h2>
        <div className="evm-steps">
          {STEPS.map((s) => (
            <div className="evm-step" key={s.n}>
              <div className="evm-step-n">{s.n}</div>
              <h3>{s.title}</h3>
              <p>{s.body}</p>
            </div>
          ))}
        </div>
      </section>

      {/* VM types */}
      <section className="evm-section" id="vm-types">
        <h2 className="evm-h2">Access options</h2>
        <div className="evm-types">
          {VM_TYPES.map((t) => (
            <div className={`evm-type evm-type-${t.tag}`} key={t.title}>
              <span className={`evm-type-label evm-type-label-${t.tag}`}>{t.label}</span>
              <h3><t.icon size={26} /> {t.title}</h3>
              <p>{t.body}</p>
            </div>
          ))}
        </div>
      </section>

      {/* Features */}
      <section className="evm-section" id="features">
        <h2 className="evm-h2">Features</h2>
        <div className="evm-features">
          {FEATURES.map((f) => (
            <div className="evm-feature" key={f.title}>
              <span className="evm-feature-ic"><f.icon size={24} /></span>
              <h3>{f.title}</h3>
              <p>{f.body}</p>
            </div>
          ))}
        </div>
      </section>

      {/* Beta expectations */}
      <section className="evm-section evm-beta">
        <h2 className="evm-h2">EpicVM is currently in beta.</h2>
        <p className="evm-body">
          EpicVM is still being developed and tested. Access is limited while reliability, performance,
          capacity, and provisioning are improved. Signing up does not guarantee approval or access to a
          particular desktop, game, or VM.
        </p>
        <ul className="evm-checklist">
          <li>desktops and games are assigned to approved accounts</li>
          <li>host capacity and availability are limited</li>
          <li>Gaming VMs are experimental</li>
          <li>the service is currently free</li>
        </ul>
        <p className="evm-note">
          Beta means beta. EpicVM may occasionally restart, become temporarily unavailable, or experience
          issues while new systems are tested. I'll do my best to keep the service reliable and communicate
          significant problems.
        </p>
      </section>

      {/* Free */}
      <section className="evm-section evm-free">
        <h2 className="evm-h2">Free during beta</h2>
        <p className="evm-body">
          There is currently no charge to use EpicVM during the beta. Desktop, game, and VM
          access is limited and assigned by Epic.
        </p>
      </section>

      {/* FAQ */}
      <section className="evm-section" id="faq">
        <h2 className="evm-h2">Frequently asked questions</h2>
        <div className="evm-faq">
          {FAQ.map((f) => (
            <details className="evm-faq-item" key={f.q}>
              <summary>{f.q}</summary>
              <p>{f.a}</p>
            </details>
          ))}
        </div>
      </section>

      {/* Final CTA */}
      <section className="evm-section evm-cta">
        <h2 className="evm-h2">Ready to try EpicVM?</h2>
        <p className="evm-body">Request access to the beta.</p>
        <button className="evm-btn evm-btn-primary evm-btn-lg" onClick={() => go('/signup')}>Request Access</button>
      </section>

      <footer className="evm-footer">
        <span className="evm-brand-mark sm">EV</span>
        <span>EpicVM — beta. Your PC, anywhere.</span>
      </footer>
    </div>
  )
}

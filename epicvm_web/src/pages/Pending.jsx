import React from 'react'
import { useNavigate } from 'react-router-dom'
import { Hourglass, CheckCircle, XCircle, Spinner, ArrowRight, Desktop } from '@phosphor-icons/react'
import { logout } from '../api'
import AuthShell from '../components/AuthShell'

export default function Pending({ user, onSignout }) {
  const navigate = useNavigate()
  const status = (user && user.accountStatus) || 'pending'
  const rejected = status === 'rejected'
  const approved = status === 'approved'

  async function signout() {
    await logout().catch(() => {})
    window.location.assign('/EpicVM/')
  }

  if (rejected) {
    return (
      <AuthShell title="Request Not Approved" rightLink={null}>
        <div className="evm-auth-card evm-pending evm-rejected">
          <span className="evm-status-badge bad"><XCircle size={20} /> rejected</span>
          <h1 className="evm-h1 sm">Request Not Approved</h1>
          <p className="evm-body">Your access request wasn't approved this time. Thanks for your interest — feel free to reach out if you'd like to talk about it.</p>
          <div className="evm-pending-foot">
            <a href="/EpicVM/" onClick={(e) => { e.preventDefault(); window.location.assign('/EpicVM/') }}>Back to home</a>
            <button className="evm-link-btn" onClick={signout}>Sign out</button>
          </div>
        </div>
      </AuthShell>
    )
  }

  // Approved: show provisioning / ready states.
  if (approved) {
    const title = 'Access Approved'
    const body = 'Open your workspace to see your assigned desktops, games, and VMs. If nothing is assigned yet, you can ask Epic for access from Settings.'
    return (
      <AuthShell title={title} rightLink={null}>
        <div className="evm-auth-card evm-pending">
          <span className="evm-status-badge ok"><CheckCircle size={20} /> approved</span>
          <h1 className="evm-h1 sm">{title}</h1>
          <p className="evm-body">{body}</p>
          {user && user.vmName && <div className="evm-account"><div><span>Machine</span><strong>{user.vmName}</strong></div></div>}
          <div className="evm-pending-actions">
            <button className="evm-btn evm-btn-primary evm-btn-lg" onClick={() => navigate('/portal')}>Open workspace <ArrowRight size={18} /></button>
          </div>
          <div className="evm-pending-foot">
            <a href="/EpicVM/" onClick={(e) => { e.preventDefault(); window.location.assign('/EpicVM/') }}>Back to home</a>
            <button className="evm-link-btn" onClick={signout}>Sign out</button>
          </div>
        </div>
      </AuthShell>
    )
  }

  // Pending (default).
  return (
    <AuthShell title="Access Request Received" rightLink={null}>
      <div className="evm-auth-card evm-pending">
        <span className="evm-status-badge warn"><Hourglass size={20} /> pending</span>
        <h1 className="evm-h1 sm">Access Request Received</h1>
        <p className="evm-body">Your EpicVM account is waiting for approval. Epic will review your request. After approval, your workspace will show any desktops, games, or VMs assigned to you.</p>
        <div className="evm-pending-foot">
          <a href="/EpicVM/" onClick={(e) => { e.preventDefault(); window.location.assign('/EpicVM/') }}>Back to home</a>
          <button className="evm-link-btn" onClick={signout}>Sign out</button>
        </div>
      </div>
    </AuthShell>
  )
}

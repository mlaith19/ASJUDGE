document.addEventListener('DOMContentLoaded', () => {
  // Auto-dismiss alerts after 5 seconds
  document.querySelectorAll('.alert').forEach(alert => {
    setTimeout(() => {
      alert.style.transition = 'opacity 0.3s';
      alert.style.opacity = '0';
      setTimeout(() => alert.remove(), 300);
    }, 5000);
  });

  // Auto-refresh dashboard every 30 seconds
  if (window.location.pathname.includes('/admin/dashboard')) {
    setTimeout(() => window.location.reload(), 30000);
  }
});

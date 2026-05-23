/* LLDPq-IB shared UI helpers
 * --------------------------------------------------------------------------
 * Drop in once with:  <script src="/css/lldpq-ib.js"></script>
 * Then use:
 *   await LLDPqUI.confirm({title, message, confirmText, danger})
 *   await LLDPqUI.alert({title, message, type: 'info'|'warning'|'error'})
 * Both return a Promise. confirm() resolves to true/false, alert() resolves
 * to undefined when dismissed.
 *
 * Replaces the browser's native confirm()/alert() with a dark-theme modal
 * that matches the LLDPq-IB design system (#1e1e1e bg, #76b900 accent).
 */
(function () {
    'use strict';

    function injectStyles() {
        if (document.getElementById('lldpq-ui-styles')) return;
        const s = document.createElement('style');
        s.id = 'lldpq-ui-styles';
        s.textContent = `
.lldpq-ui-overlay {
    position: fixed; inset: 0; background: rgba(0,0,0,0.72);
    z-index: 100000; display: flex; align-items: center; justify-content: center;
    opacity: 0; transition: opacity .12s ease;
}
.lldpq-ui-overlay.open { opacity: 1; }
.lldpq-ui-modal {
    background: #1e1e1e; border: 1px solid #404040; border-radius: 10px;
    width: 420px; max-width: 92vw;
    box-shadow: 0 16px 50px rgba(0,0,0,0.65);
    transform: translateY(8px); transition: transform .12s ease;
    overflow: hidden;
    font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
}
.lldpq-ui-overlay.open .lldpq-ui-modal { transform: translateY(0); }
.lldpq-ui-head {
    padding: 16px 20px; background: #252526; border-bottom: 1px solid #3c3c3c;
    color: #76b900; font-weight: 600; font-size: 14px;
}
.lldpq-ui-head.danger  { color: #f44336; }
.lldpq-ui-head.warning { color: #ff9800; }
.lldpq-ui-head.error   { color: #f44336; }
.lldpq-ui-body {
    padding: 18px 22px; color: #d4d4d4; font-size: 13px; line-height: 1.55;
    max-height: 60vh; overflow-y: auto;
}
.lldpq-ui-foot {
    padding: 12px 18px; background: #252526; border-top: 1px solid #3c3c3c;
    display: flex; justify-content: flex-end; gap: 8px;
}
.lldpq-ui-btn {
    border: 0; padding: 8px 18px; border-radius: 4px; cursor: pointer;
    font-size: 13px; font-weight: 500;
}
.lldpq-ui-btn-cancel  { background: #404040; color: #fff; }
.lldpq-ui-btn-cancel:hover { background: #4a4a4a; }
.lldpq-ui-btn-primary { background: #76b900; color: #000; font-weight: 600; }
.lldpq-ui-btn-primary:hover { background: #8cd000; }
.lldpq-ui-btn-danger  { background: #c53030; color: #fff; font-weight: 600; }
.lldpq-ui-btn-danger:hover { background: #d83d3d; }
`;
        document.head.appendChild(s);
    }

    function openModal({ title, message, buttons, headClass }) {
        injectStyles();
        return new Promise((resolve) => {
            const overlay = document.createElement('div');
            overlay.className = 'lldpq-ui-overlay';
            overlay.innerHTML = `
                <div class="lldpq-ui-modal">
                    <div class="lldpq-ui-head ${headClass || ''}">${title}</div>
                    <div class="lldpq-ui-body">${message}</div>
                    <div class="lldpq-ui-foot">
                        ${buttons.map((b, i) => `<button data-idx="${i}" class="lldpq-ui-btn lldpq-ui-btn-${b.style || 'cancel'}">${b.label}</button>`).join('')}
                    </div>
                </div>`;
            document.body.appendChild(overlay);
            requestAnimationFrame(() => overlay.classList.add('open'));

            function close(val) {
                overlay.classList.remove('open');
                setTimeout(() => {
                    if (overlay.parentNode) overlay.parentNode.removeChild(overlay);
                    resolve(val);
                }, 120);
            }

            overlay.querySelectorAll('.lldpq-ui-btn').forEach((btn) => {
                btn.addEventListener('click', () => {
                    const idx = parseInt(btn.getAttribute('data-idx'), 10);
                    close(buttons[idx].value);
                });
            });
            overlay.addEventListener('click', (e) => {
                if (e.target === overlay) close(false);
            });

            // ESC closes with cancel value
            const escHandler = (e) => {
                if (e.key === 'Escape') {
                    document.removeEventListener('keydown', escHandler);
                    close(false);
                }
            };
            document.addEventListener('keydown', escHandler);

            // Focus the primary button
            const primary = overlay.querySelector('.lldpq-ui-btn-primary, .lldpq-ui-btn-danger');
            if (primary) primary.focus();
        });
    }

    const LLDPqUI = {
        confirm(opts = {}) {
            const {
                title = 'Confirm',
                message = 'Are you sure?',
                confirmText = 'Confirm',
                cancelText  = 'Cancel',
                danger      = false,
            } = opts;
            return openModal({
                title, message,
                headClass: danger ? 'danger' : '',
                buttons: [
                    { label: cancelText,  value: false, style: 'cancel' },
                    { label: confirmText, value: true,  style: danger ? 'danger' : 'primary' },
                ],
            });
        },

        alert(opts = {}) {
            const {
                title = 'Notice',
                message = '',
                okText  = 'OK',
                type    = 'info',  // info | warning | error
            } = opts;
            return openModal({
                title, message,
                headClass: (type === 'error' || type === 'warning') ? type : '',
                buttons: [
                    { label: okText, value: true, style: 'primary' },
                ],
            });
        },
    };

    window.LLDPqUI = LLDPqUI;
    // Compatibility shim for code that calls a global showConfirmModal()
    if (typeof window.showConfirmModal !== 'function') {
        window.showConfirmModal = (title, message, onConfirm, onCancel) =>
            LLDPqUI.confirm({ title, message }).then((ok) => {
                if (ok && onConfirm) onConfirm();
                else if (!ok && onCancel) onCancel();
            });
    }
    if (typeof window.showAlertModal !== 'function') {
        window.showAlertModal = (title, message, type) =>
            LLDPqUI.alert({ title, message, type });
    }
})();

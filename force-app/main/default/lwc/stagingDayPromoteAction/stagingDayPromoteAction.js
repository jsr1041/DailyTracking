import { LightningElement, api, wire } from 'lwc';
import promote from '@salesforce/apex/DayPromotionController.promote';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent } from 'lightning/actions';
import { CurrentPageReference } from 'lightning/navigation';

export default class StagingDayPromoteAction extends LightningElement {
  @api recordId;
  @api objectApiName;

  @wire(CurrentPageReference) pageRef;

  hasRun = false;

  // ScreenAction entry point (if Salesforce calls it)
  @api async invoke() {
    console.log('[Promote] invoke() fired. recordId=', this.recordId);
    await this.runOnce();
  }

  // Fallback for when invoke() is NOT called (some orgs/containers)
  connectedCallback() {
    console.log('[Promote] connectedCallback fired. recordId=', this.recordId);
    // next tick so recordId has a chance to populate
    setTimeout(() => this.runOnce(), 0);
  }

  async runOnce() {
    if (this.hasRun) return;
    this.hasRun = true;

    const id = this.resolveRecordId();
    console.log('[Promote] resolved recordId=', id, 'api recordId=', this.recordId);

    if (!id) {
      this.toast('Error', 'Could not determine recordId for this action.', 'error');
      this.safeClose();
      return;
    }

    // Safety timeout so we never spin forever
    const timeoutMs = 15000;
    let timeoutHandle;
    const timeoutPromise = new Promise((_, reject) => {
      timeoutHandle = setTimeout(() => reject(new Error('Timed out waiting for Apex response.')), timeoutMs);
    });

    try {
      this.toast('Working', 'Processing staging record…', 'info');

      const res = await Promise.race([
        promote({ recordId: id }),
        timeoutPromise
      ]);

      const msg = res?.message || 'Done.';
      const isSkipped = res?.success && !res?.dayId && msg.startsWith('Skipped:');

      let variant = 'success';
      let title = 'Success';

      if (!res?.success) {
        variant = 'error';
        title = 'Failed';
      } else if (isSkipped) {
        variant = 'info';
        title = 'Skipped';
      }

      this.toast(title, msg, variant);
    } catch (e) {
      const msg =
        e?.body?.message ||
        e?.message ||
        (typeof e === 'string' ? e : JSON.stringify(e)) ||
        'Unknown error.';
      this.toast('Error', msg, 'error');
    } finally {
      if (timeoutHandle) clearTimeout(timeoutHandle);
      this.safeClose();
    }
  }

  resolveRecordId() {
    // Prefer injected recordId
    if (this.recordId) return this.recordId;

    // Try CurrentPageReference state
    const state = this.pageRef?.state || {};
    const fromState = state.recordId || state.c__recordId;
    if (fromState) return fromState;

    // URL fallback: /lightning/r/ObjectApiName/RECORDID/view
    try {
      const path = window.location?.pathname || '';
      const parts = path.split('/');
      for (let i = 0; i < parts.length; i++) {
        const seg = parts[i];
        if (seg && (seg.length === 15 || seg.length === 18) && /^[a-zA-Z0-9]+$/.test(seg)) {
          return seg;
        }
        if (seg === 'r' && parts[i + 2] && (parts[i + 2].length === 15 || parts[i + 2].length === 18)) {
          return parts[i + 2];
        }
      }
    } catch (_) {}

    return null;
  }

  toast(title, message, variant) {
    this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
  }

  safeClose() {
    try {
      this.dispatchEvent(new CloseActionScreenEvent());
    } catch (_) {
      // ignore
    }
  }
}
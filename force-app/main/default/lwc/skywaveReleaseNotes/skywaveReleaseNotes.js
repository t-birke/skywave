import { LightningElement, wire } from 'lwc';
import getRecentReleases from '@salesforce/apex/Skywave_ReleaseNotesController.getRecentReleases';

/**
 * Demo Home changelog panel — lists the most recent releases (newest first),
 * each with its version, date, optional title, grouped notes, and a link to
 * the GitHub Release. Records are written by the release-notes GitHub Action.
 */
export default class SkywaveReleaseNotes extends LightningElement {
    releases = [];
    error;
    loaded = false;

    @wire(getRecentReleases)
    wired({ data, error }) {
        if (data) {
            this.releases = data.map((r) => ({
                ...r,
                key: r.version,
                hasUrl: !!r.url
            }));
            this.error = undefined;
        } else if (error) {
            this.error = (error && error.body && error.body.message) || 'Could not load release notes';
        }
        this.loaded = true;
    }

    get hasReleases() {
        return this.releases && this.releases.length > 0;
    }

    get showEmpty() {
        return this.loaded && !this.error && !this.hasReleases;
    }
}

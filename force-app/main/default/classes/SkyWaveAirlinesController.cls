public class SkyWaveAirlinesController {

    public String orgId { get; private set; }
    public String siteUrl { get; private set; }
    public String scrt2Url { get; private set; }
    public String bootstrapUrl { get; private set; }

    public SkyWaveAirlinesController() {
        orgId = UserInfo.getOrganizationId();

        // URL.getOrgDomainUrl() returns https://{prefix}.my.salesforce.com
        String orgDomain = URL.getOrgDomainUrl().toExternalForm();
        String prefix = orgDomain.replace('https://', '').replace('.my.salesforce.com', '');

        siteUrl = 'https://' + prefix + '.my.site.com/ESWSkywaveMIAW';
        scrt2Url = 'https://' + prefix + '.my.salesforce-scrt.com';
        bootstrapUrl = siteUrl + '/assets/js/bootstrap.min.js';
    }
}

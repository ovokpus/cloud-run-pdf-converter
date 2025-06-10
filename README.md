# cloud-run-deployment
Build a Serverless App with Cloud Run that Creates PDF Files with Javascript and PubSub

Here’s a comprehensive playbook you can drop into your repo’s README. It walks through each task—explains the core concepts, shows the commands you’ll run, and highlights why each step matters.

> **Summary:** In this guide, you’ll build a fully serverless DOCX-to-PDF conversion pipeline using Google Cloud Run, Cloud Build, Cloud Storage, and Pub/Sub. You’ll containerize a Node.js/LibreOffice converter, automate builds, deploy a secure, scale-to-zero service, and wire in event-driven triggers so that every file uploaded is automatically converted and stored—effortlessly and cost-efficiently.

---

## Business Use Cases

* **Reliable Invoicing:** Customers often struggle to open DOCX attachments. Automating conversion to PDF ensures universal readability, boosting satisfaction and reducing support overhead.
* **Cost-Effective Automation:** By leveraging serverless, you pay only for actual conversion time—zero cost when idle—and offload all infrastructure management to Google ([cloud.google.com][1]).
* **Backlog Processing:** Beyond real-time uploads, you can batch-convert years of historical invoices without provisioning or managing VMs.

---

## Prerequisites

* A Google Cloud project with billing enabled
* **gcloud CLI** installed and authenticated (`gcloud init`)
* **Cloud Shell** (or any environment with Docker, Node.js, and `gsutil`)

---

## 1. Understand the Requirements

You need a REST endpoint that:

1. Listens for Pub/Sub push messages from Cloud Storage notifications.
2. Downloads the specified file to its local `/tmp`.
3. Runs `libreoffice --headless --convert-to pdf`.
4. Uploads the resulting PDF to a separate bucket.
5. Deletes the original file—keeping your staging bucket clean.

---

## 2. Enable the Cloud Run Admin API

Cloud Run is a fully managed, serverless compute platform that runs stateless containers and scales them down to zero when idle ([cloud.google.com][1]).

1. In the GCP Console go to **APIs & Services → Library**.
2. Search for **Cloud Run Admin API** and click **Enable**.

---

## 3. Containerize the PDF Converter

### Concepts:

* **Containers** package code + dependencies into immutable images, ensuring consistent behavior everywhere ([medium.com][2]).
* **LibreOffice** provides headless conversion of office documents to PDFs.

### Dockerfile Manifest

```dockerfile
FROM node:20

# Install LibreOffice for PDF conversion
RUN apt-get update -y \
    && apt-get install -y libreoffice \
    && apt-get clean

WORKDIR /usr/src/app
COPY package.json package*.json ./
RUN npm install --only=production
COPY . .
CMD ["npm", "start"]
```

This manifest:

* Uses Node.js 20 as the base.
* Installs LibreOffice so your container can convert files.
* Declares `npm start` as the entrypoint.

---

## 4. Build & Push with Cloud Build

**Cloud Build** automates container builds and pushes to Artifact Registry (or Container Registry) ([cloud.google.com][3]).
Create `cloudbuild.yaml`:

```yaml
steps:
- name: 'gcr.io/cloud-builders/docker'
  args: ['build', '-t', 'gcr.io/$PROJECT_ID/pdf-converter:latest', '.']
images:
- 'gcr.io/$PROJECT_ID/pdf-converter:latest'
```

Run:

```bash
gcloud builds submit --config cloudbuild.yaml .
```

This spins up a managed build, executes your Dockerfile, and stores the image.

---

## 5. Deploy the Service to Cloud Run

Deploy a private (authenticated) endpoint that scales to zero when idle ([developers.google.com][4]):

```bash
gcloud run deploy pdf-converter \
  --image gcr.io/$GOOGLE_CLOUD_PROJECT/pdf-converter:latest \
  --platform managed \
  --region us-west1 \
  --memory=512Mi \
  --no-allow-unauthenticated \
  --max-instances=1
```

* `--no-allow-unauthenticated` enforces IAM checks on every request ([cloud.google.com][5]).
* `--max-instances=1` caps scale to control costs.

Capture the URL:

```bash
SERVICE_URL=$(gcloud beta run services describe pdf-converter \
  --platform managed --region us-west1 \
  --format="value(status.url)")
echo $SERVICE_URL
```

---

## 6. Wire Up Cloud Storage → Pub/Sub → Cloud Run

### 6.1 Create Buckets

```bash
gsutil mb gs://$GOOGLE_CLOUD_PROJECT-upload
gsutil mb gs://$GOOGLE_CLOUD_PROJECT-processed
```

### 6.2 Enable Pub/Sub Notifications

Tell your upload bucket to publish an `OBJECT_FINALIZE` event in JSON to topic `new-doc` ([cloud.google.com][6]):

````bash
gsutil notification create \
  -t new-doc \
  -f json \
  -e OBJECT_FINALIZE \
  gs://$GOOGLE_CLOUD_PROJECT-upload
``` :contentReference[oaicite:7]{index=7}  

### 6.3 Configure Invocation IAM  
1. Create an invoker service account:  
   ```bash
   gcloud iam service-accounts create pubsub-cloud-run-invoker \
     --display-name "PubSub Cloud Run Invoker"
````

2. Grant it the Cloud Run Invoker role on your service ([cloud.google.com][5]):

   ```bash
   gcloud run services add-iam-policy-binding pdf-converter \
     --member=serviceAccount:pubsub-cloud-run-invoker@$GOOGLE_CLOUD_PROJECT.iam.gserviceaccount.com \
     --role=roles/run.invoker \
     --platform managed \
     --region us-west1
   ```
3. Allow Pub/Sub to mint tokens for this account ([cloud.google.com][7]):

   ```bash
   PROJECT_NUMBER=$(gcloud projects describe $GOOGLE_CLOUD_PROJECT --format="value(projectNumber)")
   gcloud projects add-iam-policy-binding $GOOGLE_CLOUD_PROJECT \
     --member=serviceAccount:service-$PROJECT_NUMBER@gcp-sa-pubsub.iam.gserviceaccount.com \
     --role=roles/iam.serviceAccountTokenCreator
   ```

### 6.4 Create the Push Subscription

````bash
gcloud beta pubsub subscriptions create pdf-conv-sub \
  --topic new-doc \
  --push-endpoint=$SERVICE_URL \
  --push-auth-service-account=pubsub-cloud-run-invoker@$GOOGLE_CLOUD_PROJECT.iam.gserviceaccount.com
``` :contentReference[oaicite:10]{index=10}  

---

## 7. Verify the Trigger & Inspect Logs  
1. Upload a test file:  
   ```bash
   gsutil cp gs://spls/gsp644/sample*.docx gs://$GOOGLE_CLOUD_PROJECT-upload
````

2. In the Console, go to **Observability → Logging**, filter **Cloud Run Revision**, and run the query.
3. Look for a log entry whose text begins with `file:`—that JSON payload includes `"name": "sample.docx"`, confirming the trigger.

---

## 8. Extend the Conversion Logic & Redeploy

Replace your `index.js` with the full download/convert/upload/delete helpers (see below). Then rebuild & deploy with extra memory for LibreOffice:

```bash
gcloud builds submit --tag gcr.io/$GOOGLE_CLOUD_PROJECT/pdf-converter
gcloud run deploy pdf-converter \
  --image gcr.io/$GOOGLE_CLOUD_PROJECT/pdf-converter \
  --platform managed \
  --region us-west1 \
  --memory=2Gi \
  --no-allow-unauthenticated \
  --max-instances=1 \
  --set-env-vars PDF_BUCKET=$GOOGLE_CLOUD_PROJECT-processed
```

Giving LibreOffice 2 GiB improves conversion reliability on large documents.

---

## 9. End-to-End Testing

1. **Health check:**

   ```bash
   curl -X POST \
     -H "Authorization: Bearer $(gcloud auth print-identity-token)" \
     $SERVICE_URL
   ```

   Should return `OK`.

2. **Bulk upload script:**

   ```bash
   cat <<'EOF' > copy_files.sh
   #!/bin/bash
   SRC="gs://spls/gsp644"; DST="gs://${GOOGLE_CLOUD_PROJECT}-upload"; DELAY=5
   for f in $(gsutil ls $SRC); do gsutil cp $f $DST && echo "Copied $f"; sleep $DELAY; done
   EOF
   bash copy_files.sh
   ```

3. **Observe** the `-upload` bucket in Console—files appear then vanish.

4. **Inspect** the `-processed` bucket—PDFs should now be present and viewable.

---

With this playbook in your README, new team members can onboard in minutes, understand each concept, and see exactly how to reproduce and extend your serverless PDF-conversion pipeline.

[1]: https://cloud.google.com/serverless?utm_source=chatgpt.com "Serverless | Google Cloud"
[2]: https://medium.com/%40sadoksmine8/serverless-architectures-building-with-google-cloud-run-a-detailed-guide-0aa219d75387?utm_source=chatgpt.com "Serverless Architectures: Building with Google Cloud Run - Medium"
[3]: https://cloud.google.com/build/docs/building/build-containers?utm_source=chatgpt.com "Build container images | Cloud Build Documentation - Google Cloud"
[4]: https://developers.google.com/learn/pathways/cloud-run-serverless-computing?utm_source=chatgpt.com "Cloud Run and serverless computing - Google for Developers"
[5]: https://cloud.google.com/run/docs/authenticating/public?utm_source=chatgpt.com "Allowing public (unauthenticated) access | Cloud Run Documentation"
[6]: https://cloud.google.com/storage/docs/pubsub-notifications?utm_source=chatgpt.com "Pub/Sub notifications for Cloud Storage"
[7]: https://cloud.google.com/run/docs/authenticating/overview?utm_source=chatgpt.com "Authentication overview | Cloud Run Documentation"

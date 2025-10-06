pipeline {
    agent {
        label "build-slave || single-executor-nodes"
    }
    stages {
        stage ("Run CI/CD") {
            steps {
                script {
                    if (env.CHANGE_BRANCH) { // pull request
                        build job: 'runfile-installer/dev-jenkins', propagate: true, parameters: [string(name: 'GITHUB_BRANCH', value: "${env.CHANGE_BRANCH}")]
                    } else {
                        build job: 'runfile-installer/dev-jenkins', propagate: true, parameters: [string(name: 'GITHUB_BRANCH', value: "${env.BRANCH_NAME}")]
                    }
                }
            }
        }
    }
    post {
        failure {
            script {
                if (env.BRANCH_NAME == "develop") {
                    emailext body: "Job failure on build URL: ${env.JOB_URL}${env.BUILD_NUMBER}", subject: "[Runfile CI/CD]: Job Failure on ${env.JOB_NAME} #${env.BUILD_NUMBER}", from: 'noreply@amd.com', to: "parag.bhandari@amd.com,david.bielecki@amd.com,lsudarsh@amd.com,ocherkay@amd.com"
                }
            }
        }
    }
}